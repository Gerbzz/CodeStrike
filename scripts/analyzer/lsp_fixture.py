"""Small bounded LSP client for disposable CodeStrike analyzer CI fixtures."""

import json
import os
from pathlib import Path
import queue
import subprocess
import threading
import time

INVALID = 'use std::io::Read;\nfn main() { let value: i32 = "wrong"; println!("{value}"); }\n'
VALID = INVALID.replace('"wrong"', '7')
BOOL = INVALID.replace('"wrong"', 'true')
MAX_FRAME = 4 * 1024 * 1024


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


def write_frame(stream, message):
    body = json.dumps(message, separators=(",", ":")).encode("utf-8")
    if len(body) > MAX_FRAME:
        raise ValueError("LSP fixture request too large")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
    stream.flush()


class Client:
    def __init__(self, binary, root, extra_env=None):
        self.root = Path(root).resolve()
        env = os.environ.copy()
        env.update({"CARGO_NET_OFFLINE": "true", "RA_LOG": "rust_analyzer=warn"})
        env.update(extra_env or {})
        self.process = subprocess.Popen([str(Path(binary).resolve())], cwd=self.root, env=env,
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, bufsize=0)
        self.inbox = queue.Queue()
        self.next_id = 1000
        self.replies = {}
        self.diagnostics = []
        self.diagnostics_overflow = False
        self.progress = []
        self.status = []
        self.stderr_tail = bytearray()
        threading.Thread(target=self._reader, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

    def _reader(self):
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
            chunk = self.process.stderr.readline()
            if not chunk:
                return
            self.stderr_tail.extend(chunk)
            if len(self.stderr_tail) > 4096:
                del self.stderr_tail[:-4096]

    def notify(self, method, params):
        write_frame(self.process.stdin, {"jsonrpc": "2.0", "method": method, "params": params})

    def _handle(self, message):
        method = message.get("method")
        if method and "id" in message:
            if method == "workspace/configuration":
                result = [{} for _ in message.get("params", {}).get("items", [])]
            elif method == "workspace/workspaceFolders":
                result = [{"uri": self.root.as_uri() + "/", "name": self.root.name}]
            elif method in ("window/workDoneProgress/create", "client/registerCapability",
                            "client/unregisterCapability"):
                result = None
            else:
                write_frame(self.process.stdin, {"jsonrpc": "2.0", "id": message["id"],
                                                        "error": {"code": -32601, "message": "Unsupported fixture request"}})
                return
            write_frame(self.process.stdin, {"jsonrpc": "2.0", "id": message["id"], "result": result})
        elif method == "textDocument/publishDiagnostics":
            params = message.get("params", {})
            self.diagnostics.append({"uri": params.get("uri", ""), "version": params.get("version"),
                                     "diagnostics": params.get("diagnostics", [])})
            if len(self.diagnostics) > 128:
                self.diagnostics_overflow = True
            self.diagnostics = self.diagnostics[-128:]
        elif method == "$/progress":
            params = message.get("params", {})
            value = params.get("value", {})
            if isinstance(value, dict) and value.get("kind") in ("begin", "end"):
                self.progress.append({"token": str(params.get("token", "")), "kind": value["kind"]})
                self.progress = self.progress[-128:]
        elif method == "experimental/serverStatus":
            self.status.append(message.get("params", {}))
            self.status = self.status[-32:]
        elif "id" in message:
            self.replies[message["id"]] = message

    def pump(self, seconds=0.5):
        try:
            kind, value = self.inbox.get(timeout=seconds)
        except queue.Empty:
            if self.process.poll() is not None:
                raise RuntimeError("Analyzer exited: " + self.stderr_tail.decode(errors="replace")[-600:])
            return
        if kind != "message":
            raise RuntimeError(f"LSP reader {kind}: {value}")
        self._handle(value)

    def wait(self, predicate, seconds, description):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate():
                return
            self.pump(min(0.5, max(0.01, deadline - time.monotonic())))
        raise TimeoutError(description)

    def request(self, method, params, seconds=15):
        self.next_id += 1
        request_id = self.next_id
        write_frame(self.process.stdin, {"jsonrpc": "2.0", "id": request_id,
                                                "method": method, "params": params})
        self.wait(lambda: request_id in self.replies, seconds, method)
        reply = self.replies.pop(request_id)
        if "error" in reply:
            raise RuntimeError(f"{method}: {reply['error']}")
        return reply.get("result")

    def initialize(self, options, files):
        root_uri = self.root.as_uri() + "/"
        self.request("initialize", {
            "processId": os.getpid(), "rootUri": root_uri, "rootPath": str(self.root),
            "workspaceFolders": [{"uri": root_uri, "name": self.root.name}],
            "capabilities": {"workspace": {"workspaceFolders": True, "configuration": True},
                             "textDocument": {"synchronization": {"dynamicRegistration": False},
                                              "publishDiagnostics": {"versionSupport": True},
                                              "codeAction": {"codeActionLiteralSupport": {
                                                  "codeActionKind": {"valueSet": ["quickfix"]}}}},
                             "window": {"workDoneProgress": True},
                             "experimental": {"serverStatusNotification": True}},
            "initializationOptions": options,
        }, 35)
        self.notify("initialized", {})
        for path, text in files:
            self.notify("textDocument/didOpen", {"textDocument": {
                "uri": Path(path).as_uri(), "languageId": "rust", "version": 1, "text": text}})
        self.wait(lambda: bool(self.status and self.status[-1].get("quiescent") is True),
                  90, "analyzer workspace quiescence")

    def reports(self, uri, version=None):
        return [item for item in self.diagnostics
                if item["uri"].casefold() == uri.casefold()
                and (version is None or item["version"] == version)]

    def edit(self, path, version, text):
        Path(path).write_bytes(text.encode("utf-8"))
        self.notify("textDocument/didChange", {"textDocument": {"uri": Path(path).as_uri(),
                                                         "version": version},
                                                "contentChanges": [{"text": text}]})

    def exact(self, path, text):
        uri = Path(path).as_uri()
        server = self.request("rust-analyzer/viewFileText", {"uri": uri}, 12)
        return server == text and Path(path).read_bytes() == text.encode("utf-8")

    def hold(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            self.pump(min(0.5, max(0.01, deadline - time.monotonic())))

    def close(self):
        if self.process.poll() is not None:
            return False
        try:
            self.request("shutdown", None, 5)
            self.notify("exit", {})
            self.process.wait(timeout=5)
            return True
        except (OSError, TimeoutError, subprocess.TimeoutExpired, RuntimeError):
            self.process.kill()
            self.process.wait(timeout=5)
            return False


def fixture(base, main=INVALID, other=None):
    root = Path(base) / "fixture"
    source = root / "src/main.rs"
    source.parent.mkdir(parents=True, exist_ok=False)
    (root / "Cargo.toml").write_bytes(
        b'[package]\nname = "codestrike_analyzer_gate"\nversion = "0.1.0"\nedition = "2021"\n')
    source.write_bytes(main.encode("utf-8"))
    other_path = root / "src/other.rs"
    if other is not None:
        other_path.write_bytes(other.encode("utf-8"))
    subprocess.run(["cargo", "generate-lockfile", "--offline", "--manifest-path",
                    str(root / "Cargo.toml")], check=True, capture_output=True, text=True)
    return root, source, other_path


def options(check_on_save=False):
    settings = {"checkOnSave": check_on_save, "cargo": {"buildScripts": {"enable": False}},
                "procMacro": {"enable": False}, "numThreads": 8}
    if check_on_save:
        settings["check"] = {"overrideCommand": ["cargo", "check", "--message-format=json"],
                             "invocationStrategy": "once"}
    return settings
