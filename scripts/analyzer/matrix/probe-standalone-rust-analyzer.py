"""Bounded, fixture-only LSP control for CodeStrike's hosted Rust GUI evidence.

Uses Python's standard library and the runner's official rust-analyzer component.
No CodeStrike, Lapce, Volt, or user workspace is loaded.
"""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import tomllib
import urllib.request
from urllib.parse import urlparse


INVALID = 'use std::io::Read;\nfn main() { let value: i32 = "wrong"; println!("{value}"); }'
VALID = 'use std::io::Read;\nfn main() { let value: i32 = 7; println!("{value}"); }'
DISTINCT_INVALID = INVALID + '\n// restored v3 has distinct bytes\n'
DEFAULT_OPTIONS = {"checkOnSave": False, "serverPath": "rust-analyzer"}
DISABLED_OPTIONS = {**DEFAULT_OPTIONS, "cargo": {"buildScripts": {"enable": False}},
                    "procMacro": {"enable": False}}
MAX_FRAME = 2 * 1024 * 1024
PRIOR_TOOLCHAIN = "1.98.1"
PRIOR_TARGET = "x86_64-pc-windows-msvc"
PRIOR_MANIFEST = f"https://static.rust-lang.org/dist/channel-rust-{PRIOR_TOOLCHAIN}.toml"


def write_frame(stream, message):
    body = json.dumps(message, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
    stream.flush()


def read_frame(stream):
    headers = {}
    while True:
        line = stream.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        name, separator, value = line.partition(b":")
        if not separator:
            raise ValueError("Malformed LSP header")
        headers[name.strip().lower()] = value.strip()
    length = int(headers[b"content-length"])
    if length < 0 or length > MAX_FRAME:
        raise ValueError("LSP frame exceeds fixture bound")
    body = bytearray()
    while len(body) < length:
        chunk = stream.read(length - len(body))
        if not chunk:
            raise EOFError("Truncated LSP frame")
        body.extend(chunk)
    return json.loads(body)


def is_reply(message, request_id):
    return (message.get("id") == request_id and "method" not in message
            and ("result" in message or "error" in message))


def classify_main_loop_line(line):
    """Reduce fixture-only analyzer trace to bounded event kinds without raw log text."""
    if "updating notifications for" in line:
        tail = line.split("updating notifications for", 1)[1]
        return {"kind": "update_diagnostics", "subscriptions": tail.count("FileId(")}
    if "handle_event" not in line:
        return None
    for marker, kind in (
        ('method: "textDocument/didOpen"', "did_open"),
        ('method: "textDocument/didChange"', "did_change"),
        ("Diagnostics(Syntax", "syntax_result"),
        ("Diagnostics(Semantic", "semantic_result"),
        ("FetchBuildData", "build_data_event"),
        ("LoadProcMacros", "proc_macro_event"),
    ):
        if marker in line:
            return {"kind": kind}
    return None


class Client:
    def __init__(self, argv, root, deadline, case, toolchain=None, trace_main_loop=False):
        env = os.environ.copy()
        env["CARGO_NET_OFFLINE"] = "true"
        env["RA_LOG"] = ("rust_analyzer=warn,rust_analyzer::main_loop=trace"
                         if trace_main_loop else "rust_analyzer=warn")
        if toolchain:
            env["RUSTUP_TOOLCHAIN"] = toolchain
        self.process = subprocess.Popen(
            argv,
            cwd=root,
            env=env,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        self.root = root
        self.case = case
        self.deadline = deadline
        self.started = time.monotonic()
        self.inbox = queue.Queue()
        self.diagnostics = []
        self.requests = []
        self.configuration_reply = None
        self.configuration_requests = 0
        self.progress = []
        self.server_status = []
        self.shutdown_reply_seen = False
        self.stderr = bytearray()
        self.main_loop_events = []
        self.main_loop_counts = {}
        self.diagnostic_trace_lines = []
        self.trace_main_loop = trace_main_loop
        threading.Thread(target=self._read_stdout, daemon=True).start()
        self.stderr_thread = threading.Thread(target=self._read_stderr, daemon=True)
        self.stderr_thread.start()

    def _read_stdout(self):
        try:
            while True:
                message = read_frame(self.process.stdout)
                if message is None:
                    self.inbox.put(("eof", None))
                    return
                self.inbox.put(("message", message))
        except Exception as exc:
            self.inbox.put(("error", str(exc)))

    def _read_stderr(self):
        while True:
            line = self.process.stderr.readline()
            if not line:
                return
            if len(self.stderr) < 8192:
                self.stderr.extend(line[: 8192 - len(self.stderr)])
            decoded = line.decode("utf-8", errors="replace")
            if "DIAG_" in decoded:
                self.diagnostic_trace_lines.append(decoded.strip()[-320:])
                self.diagnostic_trace_lines = self.diagnostic_trace_lines[-150:]
            if self.trace_main_loop:
                if (
                    "updating notifications for" in decoded
                    or "semantic readiness" in decoded
                    or "handle_event event=Task(Diagnostics(" in decoded
                    or "handle_event event=Task(LoadProcMacros(" in decoded
                    or "handle_event event=Task(FetchBuildData(" in decoded
                ):
                    self.diagnostic_trace_lines.append(decoded.strip()[-320:])
                    self.diagnostic_trace_lines = self.diagnostic_trace_lines[-150:]
                event = classify_main_loop_line(decoded)
                if event is not None:
                    event["t_ms"] = round((time.monotonic() - self.started) * 1000)
                    kind = event["kind"]
                    self.main_loop_counts[kind] = self.main_loop_counts.get(kind, 0) + 1
                    self.main_loop_events.append(event)
                    self.main_loop_events = self.main_loop_events[-80:]

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        write_frame(self.process.stdin, message)
        if method == "initialize":
            text_caps = params.get("capabilities", {}).get("textDocument", {})
            print("CODESTRIKE_STANDALONE_CLIENT_CAPABILITIES=" + self.case + ";" +
                  json.dumps({"pull": "diagnostic" in text_caps,
                              "push": "publishDiagnostics" in text_caps},
                             separators=(",", ":")), flush=True)
        if method in ("textDocument/didOpen", "textDocument/didChange", "textDocument/didSave"):
            version = params.get("textDocument", {}).get("version")
            print("CODESTRIKE_STANDALONE_SEND=" + self.case + ";" +
                  json.dumps({"t_ms": round((time.monotonic() - self.started) * 1000),
                              "method": method, "version": version},
                             separators=(",", ":")), flush=True)

    def _handle(self, message, source_uri):
        if "method" in message and "id" in message:
            method = message["method"]
            self.requests.append(method)
            if method == "workspace/configuration":
                self.configuration_requests += 1
                result = [self.configuration_reply
                          for _ in message.get("params", {}).get("items", [])]
            elif method == "workspace/workspaceFolders":
                result = [{"uri": self.root.as_uri(), "name": self.root.name}]
            elif method in ("window/workDoneProgress/create", "client/registerCapability"):
                result = None
            else:
                write_frame(self.process.stdin, {
                    "jsonrpc": "2.0", "id": message["id"],
                    "error": {"code": -32601, "message": "Method not supported by bounded probe"},
                })
                return
            write_frame(self.process.stdin, {"jsonrpc": "2.0", "id": message["id"], "result": result})
        elif message.get("method") == "textDocument/publishDiagnostics":
            params = message.get("params", {})
            uri = params.get("uri", "")
            if uri.casefold() != source_uri.casefold():
                return
            codes = [item.get("code") for item in params.get("diagnostics", [])]
            observation = {
                "t_ms": round((time.monotonic() - self.started) * 1000),
                "version": params.get("version"),
                "codes": codes,
                "details": [
                    {"code": item.get("code"), "source": str(item.get("source", ""))[:60],
                     "range": item.get("range"), "message": str(item.get("message", ""))[:180]}
                    for item in params.get("diagnostics", [])[:8]
                ],
            }
            self.diagnostics.append(observation)
            self.diagnostics = self.diagnostics[-64:]
            print("CODESTRIKE_STANDALONE_DIAGNOSTIC=" + self.case + ";" +
                  json.dumps(observation, separators=(",", ":")), flush=True)
        elif message.get("method") == "$/progress":
            params = message.get("params", {})
            value = params.get("value", {})
            if isinstance(value, dict) and value.get("kind") in ("begin", "end"):
                observation = {"token": str(params.get("token"))[:90], "kind": value["kind"],
                               "title": str(value.get("title", ""))[:90],
                               "message": str(value.get("message", ""))[:140]}
                self.progress.append(observation)
                self.progress = self.progress[-64:]
                if len(self.progress) <= 24:
                    print("CODESTRIKE_STANDALONE_PROGRESS=" + self.case + ";" +
                          json.dumps(observation, separators=(",", ":")), flush=True)
        elif message.get("method") == "experimental/serverStatus":
            params = message.get("params", {})
            observation = {"t_ms": round((time.monotonic() - self.started) * 1000),
                           "health": params.get("health"), "quiescent": params.get("quiescent"),
                           "message": str(params.get("message", ""))[:700]}
            self.server_status.append(observation)
            self.server_status = self.server_status[-24:]
            if len(self.server_status) <= 12:
                print("CODESTRIKE_STANDALONE_SERVER_STATUS=" + self.case + ";" +
                      json.dumps(observation, separators=(",", ":")), flush=True)

    def wait_for(self, predicate, source_uri, seconds, description):
        end = min(self.deadline, time.monotonic() + seconds)
        while time.monotonic() < end:
            try:
                kind, value = self.inbox.get(timeout=min(0.5, max(0.01, end - time.monotonic())))
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError(f"Server exited while waiting for {description}: {self.process.returncode}")
                continue
            if kind != "message":
                raise RuntimeError(f"LSP reader {kind} while waiting for {description}: {value}")
            self._handle(value, source_uri)
            if predicate(value):
                return value
        raise TimeoutError(f"No {description} within {seconds}s")

    def close(self, source_uri):
        if self.process.poll() is None:
            try:
                self.send("shutdown", None, request_id=99)
                response = self.wait_for(lambda msg: is_reply(msg, 99), source_uri, 3, "shutdown response")
                self.shutdown_reply_seen = "result" in response
                if not self.shutdown_reply_seen:
                    raise RuntimeError("Shutdown did not return a result response")
                self.send("exit", {})
                self.process.wait(timeout=3)
            except (BrokenPipeError, OSError, TimeoutError, subprocess.TimeoutExpired, RuntimeError):
                self.process.kill()
                self.process.wait(timeout=3)
        self.stderr_thread.join(timeout=2)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def make_fixture(base):
    root = base / "fixture"
    source = root / "src" / "main.rs"
    source.parent.mkdir(parents=True, exist_ok=True)
    (root / "Cargo.toml").write_bytes(b'[package]\nname = "codestrike_lsp_fixture"\nversion = "0.1.0"\nedition = "2021"\n')
    source.write_bytes(INVALID.encode("utf-8"))
    return root, source


def diag_at(message, uri, version, has_error):
    if message.get("method") != "textDocument/publishDiagnostics":
        return False
    params = message.get("params", {})
    if params.get("uri", "").casefold() != uri.casefold() or params.get("version") != version:
        return False
    codes = [entry.get("code") for entry in params.get("diagnostics", [])]
    return ("E0308" in codes) == has_error


def summarize_analyzer_status(value, root):
    if not isinstance(value, str):
        return {"unexpected_result_type": type(value).__name__}
    workspaces = value.split("\nAnalysis:\n", 1)[0]
    analysis = value.split("\nAnalysis:\n", 1)[-1].split("\nVersion: \n", 1)[0]
    version = value.split("\nVersion: \n", 1)[-1].split("\nConfiguration: \n", 1)[0]
    configuration = value.split("\nConfiguration: \n", 1)[-1]
    loaded = re.search(r"Loaded \d+ packages? across \d+ workspaces?", workspaces)
    root_text = str(root).replace("/", "\\").casefold()
    normalized_workspaces = workspaces.replace("\\\\", "\\").replace("/", "\\").casefold()
    has_root = root_text in normalized_workspaces

    def redact(text):
        text = text.replace(str(root), "<fixture>").replace(str(root).replace("\\", "/"), "<fixture>")
        return re.sub(r"[A-Za-z]:[/\\][^\s,\]]+", "<path>", text)

    relevant = [redact(line.strip())[:150] for line in configuration.splitlines()
                if re.search(r"cargo|build.?scripts|proc.?macro|check.?on.?save", line, re.I)]
    effective = {}
    for key in ("cargo_buildScripts_enable", "procMacro_enable", "diagnostics_enable"):
        match = re.search(r"\b" + re.escape(key) + r":\s*(true|false)", configuration, re.I)
        effective[key] = match.group(1).lower() == "true" if match else None
    return {"loaded": loaded.group(0) if loaded else None,
            "workspace_root_mentions_fixture": has_root,
            "effective": effective,
            "analysis_excerpt": redact(analysis.strip())[:420],
            "version": version.strip()[:120],
            "configuration_relevant": relevant[:20],
            "configuration_chars": len(configuration)}


def request_analyzer_status(client, source_uri, request_id, phase):
    client.send("rust-analyzer/analyzerStatus", {"textDocument": {"uri": source_uri}}, request_id)
    try:
        response = client.wait_for(lambda msg: is_reply(msg, request_id), source_uri, 6,
                                   f"{phase} analyzerStatus response")
        summary = ({"error": str(response["error"])[:220]} if "error" in response else
                   summarize_analyzer_status(response.get("result"), client.root))
    except TimeoutError:
        summary = {"timeout_seconds": 6}
    print("CODESTRIKE_STANDALONE_ANALYZER_STATUS=" + client.case + ";" + phase + ";" +
          json.dumps(summary, separators=(",", ":")), flush=True)
    return summary


def run_probe(argv, base, options=DEFAULT_OPTIONS, case="default", total_seconds=155,
              expect_collisions=False, toolchain=None, ready_before_edit=False,
              disk_timing="before", notify_save=False, discriminate_edits=False,
              trace_main_loop=False):
    if disk_timing not in ("before", "after", "none"):
        raise ValueError("Unknown fixture disk timing")
    root, source = make_fixture(base)
    root_uri = root.as_uri() + "/"
    source_uri = source.as_uri()
    client = Client(argv, root, time.monotonic() + total_seconds, case, toolchain,
                    trace_main_loop=trace_main_loop)
    stages = {"initial_error": False, "valid_removes_error": None, "reintroduced_error": False}
    valid_v2_published = False
    v2_server_matches = None
    v3_server_matches = None
    v3_text = DISTINCT_INVALID if discriminate_edits else INVALID
    statuses = []
    print("CODESTRIKE_STANDALONE_FIXTURE=" + case + ";rust-cargo;toolchain:" +
          (toolchain or "runner-default") + ";options:" +
          json.dumps(options, separators=(",", ":")), flush=True)
    try:
        client.send("initialize", {
            "processId": os.getpid(),
            "clientInfo": {"name": "CodeStrike standalone control", "version": "1"},
            "rootUri": root_uri,
            "rootPath": str(root),
            "workspaceFolders": [{"uri": root_uri, "name": root.name}],
            "capabilities": {
                "workspace": {"workspaceFolders": True, "configuration": True},
                "textDocument": {"synchronization": {"dynamicRegistration": False},
                                 "publishDiagnostics": {"versionSupport": True}},
                "window": {"workDoneProgress": True},
                "experimental": {"serverStatusNotification": True},
            },
            "initializationOptions": options,
        }, request_id=1)
        response = client.wait_for(lambda msg: is_reply(msg, 1), source_uri, 35, "initialize response")
        if "error" in response:
            raise RuntimeError("rust-analyzer rejected initialize: " + str(response["error"])[:300])
        if "result" not in response:
            raise RuntimeError("Initialize did not return a result response")
        server_caps = response.get("result", {}).get("capabilities", {})
        print("CODESTRIKE_STANDALONE_SERVER_CAPABILITIES=" + case + ";" +
              json.dumps({"diagnosticProvider": "diagnosticProvider" in server_caps},
                         separators=(",", ":")), flush=True)
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {"uri": source_uri, "languageId": "rust", "version": 1, "text": INVALID}
        })
        try:
            client.wait_for(lambda msg: diag_at(msg, source_uri, 1, True), source_uri, 45, "initial v1 E0308")
            stages["initial_error"] = True
        except TimeoutError:
            print("CODESTRIKE_STANDALONE_TIMEOUT=" + case + ";initial-v1-E0308", flush=True)
        statuses.append(request_analyzer_status(client, source_uri, 2, "after-v1"))
        if ready_before_edit:
            if not client.server_status or client.server_status[-1].get("quiescent") is not True:
                client.wait_for(
                    lambda msg: msg.get("method") == "experimental/serverStatus"
                    and msg.get("params", {}).get("quiescent") is True,
                    source_uri, 35, "first analyzer quiescence before edits")
            print("CODESTRIKE_STANDALONE_READY=" + case + ";before-edits", flush=True)

        if disk_timing == "before":
            source.write_bytes(VALID.encode("utf-8"))
        client.send("textDocument/didChange", {
            "textDocument": {"uri": source_uri, "version": 2},
            "contentChanges": [{"text": VALID}],
        })
        if disk_timing == "after":
            source.write_bytes(VALID.encode("utf-8"))
        if notify_save:
            client.send("textDocument/didSave", {"textDocument": {"uri": source_uri}})
        print("CODESTRIKE_STANDALONE_CHANGE=" + case + ";version:2;diskSha256:" +
              hashlib.sha256(source.read_bytes()).hexdigest(), flush=True)
        if stages["initial_error"]:
            stages["valid_removes_error"] = False
            try:
                client.wait_for(lambda msg: diag_at(msg, source_uri, 2, False), source_uri, 40, "valid v2 without E0308")
                stages["valid_removes_error"] = True
            except TimeoutError:
                print("CODESTRIKE_STANDALONE_TIMEOUT=" + case + ";valid-v2-without-E0308", flush=True)
        else:
            # With no initial error to remove, an unchanged empty set can be deduplicated.
            try:
                client.wait_for(lambda msg: diag_at(msg, source_uri, 2, False), source_uri, 10, "valid v2 publication")
                valid_v2_published = True
            except TimeoutError:
                print("CODESTRIKE_STANDALONE_VALID=" + case +
                      ";unobserved-after-empty-v1;removal-inconclusive", flush=True)

        if discriminate_edits:
            client.send("rust-analyzer/viewFileText", {"uri": source_uri}, request_id=5)
            try:
                reply = client.wait_for(lambda msg: is_reply(msg, 5), source_uri, 6,
                                        "viewFileText response at valid v2")
                server_text = reply.get("result")
                v2_server_matches = isinstance(server_text, str) and server_text == VALID
                observation = (
                    {"error": str(reply["error"])[:180]} if "error" in reply else
                    {"serverSha256": hashlib.sha256(server_text.encode("utf-8")).hexdigest(),
                     "matches_v2": v2_server_matches, "matches_v1": server_text == INVALID,
                     "matches_disk": server_text.encode("utf-8") == source.read_bytes()}
                    if isinstance(server_text, str) else
                    {"unexpected_result_type": type(server_text).__name__}
                )
            except TimeoutError:
                observation = {"timeout_seconds": 6}
            print("CODESTRIKE_DISCRIMINATING_SERVER_TEXT=" + case + ";v2;" +
                  json.dumps(observation, separators=(",", ":")), flush=True)

        if disk_timing == "before":
            source.write_bytes(v3_text.encode("utf-8"))
        client.send("textDocument/didChange", {
            "textDocument": {"uri": source_uri, "version": 3},
            "contentChanges": [{"text": v3_text}],
        })
        if disk_timing == "after":
            source.write_bytes(v3_text.encode("utf-8"))
        if notify_save:
            client.send("textDocument/didSave", {"textDocument": {"uri": source_uri}})
        print("CODESTRIKE_STANDALONE_CHANGE=" + case + ";version:3;diskSha256:" +
              hashlib.sha256(source.read_bytes()).hexdigest(), flush=True)
        try:
            client.wait_for(lambda msg: diag_at(msg, source_uri, 3, True), source_uri, 45, "reintroduced v3 E0308")
            stages["reintroduced_error"] = True
        except TimeoutError:
            print("CODESTRIKE_STANDALONE_TIMEOUT=" + case + ";reintroduced-v3-E0308", flush=True)
            # Preserve the original post-timeout server-text observation for baseline cases.
            if not discriminate_edits:
                client.send("rust-analyzer/viewFileText", {"uri": source_uri},
                            request_id=4)
                try:
                    reply = client.wait_for(lambda msg: is_reply(msg, 4), source_uri, 6,
                                            "viewFileText response after v3 timeout")
                    server_text = reply.get("result")
                    observation = (
                        {"error": str(reply["error"])[:180]} if "error" in reply else
                        {"serverSha256": hashlib.sha256(server_text.encode("utf-8")).hexdigest(),
                         "matches_v3": server_text == v3_text,
                         "matches_disk": server_text.encode("utf-8") == source.read_bytes()}
                        if isinstance(server_text, str) else
                        {"unexpected_result_type": type(server_text).__name__}
                    )
                except TimeoutError:
                    observation = {"timeout_seconds": 6}
                print("CODESTRIKE_STANDALONE_SERVER_TEXT=" + case + ";" +
                      json.dumps(observation, separators=(",", ":")), flush=True)
        if discriminate_edits:
            client.send("rust-analyzer/viewFileText", {"uri": source_uri}, request_id=6)
            try:
                reply = client.wait_for(lambda msg: is_reply(msg, 6), source_uri, 6,
                                        "viewFileText response at distinct invalid v3")
                server_text = reply.get("result")
                v3_server_matches = isinstance(server_text, str) and server_text == v3_text
                observation = (
                    {"error": str(reply["error"])[:180]} if "error" in reply else
                    {"serverSha256": hashlib.sha256(server_text.encode("utf-8")).hexdigest(),
                     "matches_v3": v3_server_matches, "matches_v1": server_text == INVALID,
                     "matches_disk": server_text.encode("utf-8") == source.read_bytes()}
                    if isinstance(server_text, str) else
                    {"unexpected_result_type": type(server_text).__name__}
                )
            except TimeoutError:
                observation = {"timeout_seconds": 6}
            print("CODESTRIKE_DISCRIMINATING_SERVER_TEXT=" + case + ";v3;" +
                  json.dumps(observation, separators=(",", ":")), flush=True)
        if discriminate_edits:
            # Auxiliary observation only: compare a pull request after the passive
            # push window. It must not change the original push-diagnostic result.
            client.send("textDocument/diagnostic", {"textDocument": {"uri": source_uri}},
                        request_id=7)
            try:
                reply = client.wait_for(lambda msg: is_reply(msg, 7), source_uri, 12,
                                        "pull diagnostic response after passive v3 window")
                report = reply.get("result")
                observation = (
                    {"error": str(reply["error"])[:180]} if "error" in reply else
                    {"kind": report.get("kind"), "resultId": report.get("resultId"),
                     "item_count": len(report.get("items", [])),
                     "codes": [item.get("code") for item in report.get("items", [])[:12]],
                     "has_e0308": any(item.get("code") == "E0308"
                                      for item in report.get("items", []))}
                    if isinstance(report, dict) else
                    {"unexpected_result_type": type(report).__name__}
                )
            except TimeoutError:
                observation = {"timeout_seconds": 12}
            print("CODESTRIKE_DISCRIMINATING_PULL=" + case + ";" +
                  json.dumps(observation, separators=(",", ":")), flush=True)
        statuses.append(request_analyzer_status(client, source_uri, 3, "after-v3"))
    finally:
        client.close(source_uri)
        if trace_main_loop:
            print("CODESTRIKE_STANDALONE_MAIN_LOOP=" + case + ";" +
                  json.dumps({"counts": client.main_loop_counts,
                              "events": client.main_loop_events[-60:]},
                             separators=(",", ":")), flush=True)
        print("CODESTRIKE_STANDALONE_RESULT=" + case + ";" + json.dumps({
            **stages,
            "ready_before_edit": ready_before_edit,
            "disk_timing": disk_timing,
            "notify_save": notify_save,
            "valid_v2_published": valid_v2_published,
            "final_version": 3,
            "disk_matches_invalid": source.read_bytes() == v3_text.encode("utf-8"),
            "discriminate_edits": discriminate_edits,
            "v2_server_matches": v2_server_matches,
            "v3_server_matches": v3_server_matches,
            "diagnostics": client.diagnostics[-12:],
            "progress": client.progress[-24:],
            "server_status": client.server_status[-12:],
            "analyzer_status": statuses,
            "server_requests": client.requests[-12:],
            "stderr_prefix": client.stderr.decode("utf-8", errors="replace")[:400],
        }, separators=(",", ":")), flush=True)
    collisions_seen = client.requests.count("window/workDoneProgress/create") >= 2
    progress_kinds = {entry["kind"] for entry in client.progress}
    synthetic_observability = (collisions_seen and client.shutdown_reply_seen and
                               progress_kinds == {"begin", "end"} and
                               len(statuses) == 2 and all(entry.get("loaded") and
                               entry.get("workspace_root_mentions_fixture") for entry in statuses))
    return (all(stages.values()) and (not expect_collisions or synthetic_observability)
            and (not discriminate_edits or (v2_server_matches and v3_server_matches)))


def fake_server():
    current_text = None
    while True:
        message = read_frame(sys.stdin.buffer)
        if message is None:
            return
        method = message.get("method")
        if method == "initialize":
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": 1,
                                            "method": "window/workDoneProgress/create",
                                            "params": {"token": "initialize-collision"}})
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {}}})
        elif method in ("textDocument/didOpen", "textDocument/didChange"):
            document = message["params"]["textDocument"]
            version = document["version"]
            text = message["params"].get("contentChanges", [{}])[0].get("text", document.get("text", ""))
            current_text = text
            diagnostics = [{"code": "E0308", "message": "fixture"}] if '"wrong"' in text else []
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "$/progress",
                                            "params": {"token": "fixture-progress", "value": {
                                                "kind": "begin", "title": "Fixture analysis"}}})
            if version == 2:
                # A late pre-edit publication must not satisfy the valid-code stage.
                write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                                "params": {"uri": document["uri"], "version": 1,
                                                           "diagnostics": [{"code": "E0308"}]}})
            elif version == 3:
                # A different file must not satisfy the reintroduced-error stage.
                write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                                "params": {"uri": document["uri"] + ".other", "version": 3,
                                                           "diagnostics": [{"code": "E0308"}]}})
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics",
                                            "params": {"uri": document["uri"], "version": version,
                                                       "diagnostics": diagnostics}})
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "$/progress",
                                            "params": {"token": "fixture-progress", "value": {"kind": "end"}}})
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "method": "experimental/serverStatus",
                                            "params": {"health": "ok", "quiescent": True}})
        elif method == "rust-analyzer/viewFileText":
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": current_text})
        elif method == "textDocument/diagnostic":
            items = ([{"code": "E0308", "message": "fixture"}]
                     if current_text is not None and '"wrong"' in current_text else [])
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"],
                                            "result": {"kind": "full", "resultId": "fixture",
                                                       "items": items}})
        elif method == "rust-analyzer/analyzerStatus":
            status = ("Workspaces:\nLoaded 1 packages across 1 workspace.\n"
                      f"Workspace root folders: [{os.getcwd()!r}]\nAnalysis:\nFixture ready\n"
                      "Version: \nfixture\nConfiguration: \ncargo_buildScripts_enable: true")
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": status})
        elif method == "shutdown":
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": 99,
                                            "method": "window/workDoneProgress/create",
                                            "params": {"token": "shutdown-collision"}})
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": None})
        elif method == "exit":
            return


def prior_component_available(manifest):
    # rustup exposes this component as rust-analyzer; the distribution manifest
    # names its package rust-analyzer-preview.
    component = manifest.get("pkg", {}).get("rust-analyzer-preview", {}).get("target", {}).get(PRIOR_TARGET, {})
    artifact_url = component.get("url", "")
    return component.get("available") is True and urlparse(artifact_url).hostname == "static.rust-lang.org"


def verify_prior_manifest():
    if sys.platform != "win32":
        raise RuntimeError("The prior-component availability check is Windows-only")
    with urllib.request.urlopen(PRIOR_MANIFEST, timeout=15) as response:
        manifest_bytes = response.read(8 * 1024 * 1024 + 1)
    if len(manifest_bytes) > 8 * 1024 * 1024:
        raise RuntimeError("Official Rust distribution manifest exceeded the metadata bound")
    manifest = tomllib.loads(manifest_bytes.decode("utf-8"))
    if not prior_component_available(manifest):
        raise RuntimeError("Official prior rust-analyzer Windows component is unavailable in the pinned release manifest")
    print("CODESTRIKE_PRIOR_COMPONENT_AVAILABLE=" + PRIOR_TOOLCHAIN + ";target:" + PRIOR_TARGET +
          ";package:rust-analyzer-preview;manifest-date:" + str(manifest.get("date", "unknown")), flush=True)


def analyzer_version(server, toolchain):
    env = os.environ.copy()
    if toolchain:
        env["RUSTUP_TOOLCHAIN"] = toolchain
    result = subprocess.run([server, "--version"], env=env, capture_output=True,
                            text=True, timeout=12, check=True)
    version = result.stdout.strip()
    expected = "rust-analyzer " + (toolchain or "1.99.0") + " "
    if not version.startswith(expected):
        raise RuntimeError(f"Expected {expected.strip()} but found {version[:120]}")
    return version


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--fake-server", action="store_true")
    parser.add_argument("--check-prior-availability", action="store_true")
    parser.add_argument("--compare-versions", action="store_true")
    parser.add_argument("--compare-sequencing", action="store_true")
    parser.add_argument("--discriminate-edits", action="store_true")
    args = parser.parse_args()
    if args.fake_server:
        fake_server()
        return 0
    if args.check_prior_availability:
        verify_prior_manifest()
        return 0
    if args.self_test:
        manifest = tomllib.loads('date = "2026-09-03"\n[pkg.rust-analyzer-preview.target.x86_64-pc-windows-msvc]\n'
                                 'available = true\nurl = "https://static.rust-lang.org/dist/fixture.tar.xz"\n')
        assert classify_main_loop_line("TRACE updating notifications for [FileId(0)]") == {
            "kind": "update_diagnostics", "subscriptions": 1}
        assert classify_main_loop_line(
            'DEBUG handle_event event=Notification { method: "textDocument/didOpen" }') == {
                "kind": "did_open"}
        assert classify_main_loop_line(
            'DEBUG handle_event event=Notification { method: "textDocument/didChange" }') == {
                "kind": "did_change"}
        assert classify_main_loop_line("DEBUG handle_event event=Task(Diagnostics(Semantic(1, [])))") == {
            "kind": "semantic_result"}
        assert prior_component_available(manifest)
        manifest["pkg"]["rust-analyzer-preview"]["target"][PRIOR_TARGET]["available"] = False
        assert not prior_component_available(manifest)
        print("CODESTRIKE_STANDALONE_SELFTEST=official-manifest-preflight-passed", flush=True)
        class FragmentedStream(io.BytesIO):
            def read(self, count=-1):
                return super().read(min(count, 2))

        sample = {"jsonrpc": "2.0", "method": "fixture/fragmented", "params": {"text": "é🦀"}}
        encoded = io.BytesIO()
        write_frame(encoded, sample)
        assert read_frame(FragmentedStream(encoded.getvalue())) == sample
        print("CODESTRIKE_STANDALONE_SELFTEST=fragmented-frame-passed", flush=True)
        with tempfile.TemporaryDirectory(prefix="codestrike-standalone-selftest-") as path:
            fake = [sys.executable, str(Path(__file__).resolve()), "--fake-server"]
            base = Path(path)
            first = run_probe(fake, base, total_seconds=20, expect_collisions=True)
            second = run_probe(fake, base, options=DISABLED_OPTIONS, case="disabled",
                               total_seconds=20, expect_collisions=True)
            distinct = run_probe(fake, base, case="synthetic_distinct", total_seconds=25,
                                 discriminate_edits=True, expect_collisions=True)
            ok = first and second and distinct
        print("CODESTRIKE_STANDALONE_SELFTEST=colliding-request-ids-" + ("passed" if ok else "failed"), flush=True)
        print("CODESTRIKE_STANDALONE_SELFTEST=reused-fixture-path-" + ("passed" if ok else "failed"), flush=True)
        return 0 if ok else 1
    server = shutil.which("rust-analyzer")
    if not server:
        raise RuntimeError("Official rust-analyzer component is unavailable on this hosted runner")
    base = Path(tempfile.mkdtemp(prefix="codestrike-standalone-ra-", dir=os.environ.get("RUNNER_TEMP")))
    if args.discriminate_edits:
        print("CODESTRIKE_DISCRIMINATING_ANALYZER=" + analyzer_version(server, None), flush=True)
        try:
            result = run_probe([server], base, case="distinct_v2_v3", total_seconds=180,
                               discriminate_edits=True, trace_main_loop=True)
        except Exception as exc:
            result = False
            print("CODESTRIKE_DISCRIMINATING_CASE_ERROR=" + str(exc)[:300], flush=True)
        print("CODESTRIKE_DISCRIMINATING_RESULT=" + json.dumps({"passed": result},
              separators=(",", ":")), flush=True)
        return 0 if result else 1
    if args.compare_sequencing:
        print("CODESTRIKE_SEQUENCING_ANALYZER=" + analyzer_version(server, None), flush=True)
        results = {}
        for case, ready, timing, save in (
            ("original_sequence", False, "before", False),
            ("settled_sequence", True, "before", False),
            ("settled_save_control", True, "after", True),
        ):
            case_base = base / case
            case_base.mkdir()
            try:
                results[case] = run_probe([server], case_base, case=case,
                                          ready_before_edit=ready,
                                          disk_timing=timing, notify_save=save,
                                          total_seconds=155)
            except Exception as exc:
                results[case] = False
                print("CODESTRIKE_STANDALONE_CASE_ERROR=" + case + ";" + str(exc)[:300], flush=True)
        print("CODESTRIKE_SEQUENCING_COMPARISON=" +
              json.dumps(results, separators=(",", ":")), flush=True)
        return 0 if all(results.values()) else 1
    if args.compare_versions:
        versions = {"current": analyzer_version(server, None),
                    "prior": analyzer_version(server, PRIOR_TOOLCHAIN)}
        print("CODESTRIKE_VERSION_CONTROL_BINARIES=" + json.dumps(versions, separators=(",", ":")), flush=True)
        results = {}
        for case, toolchain in (("current_1", None), ("prior_1", PRIOR_TOOLCHAIN),
                                ("current_2", None), ("prior_2", PRIOR_TOOLCHAIN)):
            try:
                results[case] = run_probe([server], base, case=case, toolchain=toolchain)
            except Exception as exc:
                results[case] = False
                print("CODESTRIKE_STANDALONE_CASE_ERROR=" + case + ";" + str(exc)[:300], flush=True)
        candidate = all(results[name] for name in ("prior_1", "prior_2")) and not any(
            results[name] for name in ("current_1", "current_2"))
        print("CODESTRIKE_VERSION_COMPARISON=" + json.dumps({"runs": results,
              "candidate_compatibility_pin": candidate}, separators=(",", ":")), flush=True)
        return 0 if all(results.values()) else 1
    results = {}
    for case, options in (("default", DEFAULT_OPTIONS), ("disabled", DISABLED_OPTIONS)):
        try:
            results[case] = run_probe([server], base, options=options, case=case)
        except Exception as exc:
            results[case] = False
            print("CODESTRIKE_STANDALONE_CASE_ERROR=" + case + ";" + str(exc)[:300], flush=True)
    print("CODESTRIKE_STANDALONE_COMPARISON=" + json.dumps(results, separators=(",", ":")), flush=True)
    return 0 if all(results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
