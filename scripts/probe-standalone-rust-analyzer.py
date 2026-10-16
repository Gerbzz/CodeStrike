"""Bounded, fixture-only LSP control for CodeStrike's hosted Rust GUI evidence.

Uses Python's standard library and the runner's official rust-analyzer component.
No CodeStrike, Lapce, Volt, or user workspace is loaded.
"""

import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time


INVALID = 'use std::io::Read;\nfn main() { let value: i32 = "wrong"; println!("{value}"); }'
VALID = 'use std::io::Read;\nfn main() { let value: i32 = 7; println!("{value}"); }'
OPTIONS = {"checkOnSave": False, "serverPath": "rust-analyzer"}
MAX_FRAME = 2 * 1024 * 1024


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
    body = stream.read(length)
    if len(body) != length:
        raise EOFError("Truncated LSP frame")
    return json.loads(body)


class Client:
    def __init__(self, argv, root, deadline):
        env = os.environ.copy()
        env["CARGO_NET_OFFLINE"] = "true"
        env["RA_LOG"] = "rust_analyzer=warn"
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
        self.deadline = deadline
        self.inbox = queue.Queue()
        self.diagnostics = []
        self.requests = []
        self.stderr = bytearray()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

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
            chunk = self.process.stderr.read(4096)
            if not chunk:
                return
            if len(self.stderr) < 8192:
                self.stderr.extend(chunk[: 8192 - len(self.stderr)])

    def send(self, method, params, request_id=None):
        message = {"jsonrpc": "2.0", "method": method, "params": params}
        if request_id is not None:
            message["id"] = request_id
        write_frame(self.process.stdin, message)

    def _handle(self, message, source_uri):
        if "method" in message and "id" in message:
            method = message["method"]
            self.requests.append(method)
            if method == "workspace/configuration":
                result = [None for _ in message.get("params", {}).get("items", [])]
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
            observation = {"version": params.get("version"), "codes": codes}
            self.diagnostics.append(observation)
            self.diagnostics = self.diagnostics[-64:]
            print("CODESTRIKE_STANDALONE_DIAGNOSTIC=" + json.dumps(observation, separators=(",", ":")), flush=True)

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
                self.send("shutdown", {}, request_id=99)
                self.wait_for(lambda msg: msg.get("id") == 99, source_uri, 3, "shutdown response")
                self.send("exit", {})
                self.process.wait(timeout=3)
            except (BrokenPipeError, OSError, TimeoutError, subprocess.TimeoutExpired, RuntimeError):
                self.process.kill()
                self.process.wait(timeout=3)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()


def make_fixture(base):
    root = base / "fixture"
    source = root / "src" / "main.rs"
    source.parent.mkdir(parents=True)
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


def run_probe(argv, base, total_seconds=155):
    root, source = make_fixture(base)
    root_uri = root.as_uri() + "/"
    source_uri = source.as_uri()
    client = Client(argv, root, time.monotonic() + total_seconds)
    stages = {"initial_error": False, "valid_removes_error": False, "reintroduced_error": False}
    print("CODESTRIKE_STANDALONE_FIXTURE=rust-cargo;options:" + json.dumps(OPTIONS, separators=(",", ":")), flush=True)
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
            },
            "initializationOptions": OPTIONS,
        }, request_id=1)
        response = client.wait_for(lambda msg: msg.get("id") == 1, source_uri, 35, "initialize response")
        if "error" in response:
            raise RuntimeError("rust-analyzer rejected initialize: " + str(response["error"])[:300])
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {"uri": source_uri, "languageId": "rust", "version": 1, "text": INVALID}
        })
        try:
            client.wait_for(lambda msg: diag_at(msg, source_uri, 1, True), source_uri, 45, "initial v1 E0308")
            stages["initial_error"] = True
        except TimeoutError:
            print("CODESTRIKE_STANDALONE_TIMEOUT=initial-v1-E0308", flush=True)

        source.write_bytes(VALID.encode("utf-8"))
        client.send("textDocument/didChange", {
            "textDocument": {"uri": source_uri, "version": 2},
            "contentChanges": [{"text": VALID}],
        })
        try:
            client.wait_for(lambda msg: diag_at(msg, source_uri, 2, False), source_uri, 40, "valid v2 without E0308")
            stages["valid_removes_error"] = True
        except TimeoutError:
            print("CODESTRIKE_STANDALONE_TIMEOUT=valid-v2-without-E0308", flush=True)

        source.write_bytes(INVALID.encode("utf-8"))
        client.send("textDocument/didChange", {
            "textDocument": {"uri": source_uri, "version": 3},
            "contentChanges": [{"text": INVALID}],
        })
        try:
            client.wait_for(lambda msg: diag_at(msg, source_uri, 3, True), source_uri, 45, "reintroduced v3 E0308")
            stages["reintroduced_error"] = True
        except TimeoutError:
            print("CODESTRIKE_STANDALONE_TIMEOUT=reintroduced-v3-E0308", flush=True)
    finally:
        client.close(source_uri)
        print("CODESTRIKE_STANDALONE_RESULT=" + json.dumps({
            **stages,
            "final_version": 3,
            "disk_matches_invalid": source.read_bytes() == INVALID.encode("utf-8"),
            "diagnostics": client.diagnostics[-12:],
            "server_requests": client.requests[-12:],
            "stderr_prefix": client.stderr.decode("utf-8", errors="replace")[:400],
        }, separators=(",", ":")), flush=True)
    return all(stages.values())


def fake_server():
    while True:
        message = read_frame(sys.stdin.buffer)
        if message is None:
            return
        method = message.get("method")
        if method == "initialize":
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": {"capabilities": {}}})
        elif method in ("textDocument/didOpen", "textDocument/didChange"):
            document = message["params"]["textDocument"]
            version = document["version"]
            text = message["params"].get("contentChanges", [{}])[0].get("text", document.get("text", ""))
            diagnostics = [{"code": "E0308", "message": "fixture"}] if '"wrong"' in text else []
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
        elif method == "shutdown":
            write_frame(sys.stdout.buffer, {"jsonrpc": "2.0", "id": message["id"], "result": None})
        elif method == "exit":
            return


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--fake-server", action="store_true")
    args = parser.parse_args()
    if args.fake_server:
        fake_server()
        return 0
    if args.self_test:
        with tempfile.TemporaryDirectory(prefix="codestrike-standalone-selftest-") as path:
            ok = run_probe([sys.executable, str(Path(__file__).resolve()), "--fake-server"], Path(path), 20)
        return 0 if ok else 1
    server = shutil.which("rust-analyzer")
    if not server:
        raise RuntimeError("Official rust-analyzer component is unavailable on this hosted runner")
    base = Path(tempfile.mkdtemp(prefix="codestrike-standalone-ra-", dir=os.environ.get("RUNNER_TEMP")))
    return 0 if run_probe([server], base) else 1


if __name__ == "__main__":
    sys.exit(main())
