"""Collect public-fixture RA protocol evidence; this does not test the editor GUI."""
import json
import os
from pathlib import Path
import queue
import shutil
import subprocess
import tempfile
import threading
import time


def emit(event, **details):
    print(json.dumps({"event": event, **details}, sort_keys=True), flush=True)


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("This diagnostic is restricted to the fresh hosted CI fixture")
    server = shutil.which("rust-analyzer")
    if not server:
        raise RuntimeError("The same rust-analyzer executable must be installed first")
    sysroot = subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip()
    emit("toolchain", rustc=subprocess.check_output(["rustc", "--version"], text=True).strip(),
         server=subprocess.check_output([server, "--version"], text=True).strip(),
         rust_src_present=(Path(sysroot) / "lib/rustlib/src/rust/library/std/src/io/mod.rs").is_file(),
         installed_components=subprocess.check_output(["rustup", "component", "list", "--installed"], text=True).splitlines())
    temporary_root = Path(os.environ["RUNNER_TEMP"]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="codestrike-ra-diagnostic-", dir=temporary_root) as directory:
        Path(directory).resolve(strict=True).relative_to(temporary_root)
        root = Path(directory) / "fixture"
        (root / "src").mkdir(parents=True)
        (root / ".codestrike").mkdir()
        (root / ".codestrike/settings.toml").write_text('[lapce-rust]\nserverPath = "rust-analyzer"\ncheckOnSave = true\n', encoding="utf-8")
        application_data = Path(directory) / "appdata"
        local_data = Path(directory) / "localdata"
        application_data.mkdir()
        local_data.mkdir()
        (root / "Cargo.toml").write_text('[package]\nname = "codestrike_lsp_fixture"\nversion = "0.1.0"\nedition = "2021"\n', encoding="utf-8")
        source = root / "src/main.rs"
        text = 'use std::io::Re;\nfn main() { let value: i32 = "wrong"; println!("{value}"); }'
        source.write_text(text, encoding="utf-8", newline="")
        uri = source.as_uri()
        env = dict(os.environ, CARGO_NET_OFFLINE="true", CARGO_INCREMENTAL="0",
                   APPDATA=str(application_data), LOCALAPPDATA=str(local_data))
        process = subprocess.Popen([server], cwd=root, env=env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        messages = queue.Queue()
        stderr = []

        def stdout_reader():
            try:
                while True:
                    headers = {}
                    while True:
                        line = process.stdout.readline()
                        if not line:
                            return
                        if line in (b"\r\n", b"\n"):
                            break
                        key, value = line.decode("ascii").split(":", 1)
                        headers[key.lower()] = value.strip()
                    length = int(headers["content-length"])
                    body = process.stdout.read(length)
                    if len(body) != length:
                        raise RuntimeError("Incomplete server protocol frame")
                    messages.put(json.loads(body))
            except Exception as error:
                messages.put({"reader_error": str(error)})

        def stderr_reader():
            for line in iter(process.stderr.readline, b""):
                stderr.append(line.decode("utf-8", errors="replace").rstrip())

        stdout_thread = threading.Thread(target=stdout_reader, daemon=True)
        stderr_thread = threading.Thread(target=stderr_reader, daemon=True)
        stdout_thread.start()
        stderr_thread.start()

        def send(message):
            body = json.dumps({"jsonrpc": "2.0", **message}, separators=(",", ":")).encode()
            process.stdin.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
            process.stdin.flush()
            emit("sent", method=message.get("method"), id=message.get("id"), params=message.get("params"))

        def receive(timeout):
            message = messages.get(timeout=timeout)
            if "method" in message:
                method = message["method"]
                if method == "textDocument/publishDiagnostics":
                    params = message.get("params", {})
                    emit("diagnostics", uri=params.get("uri"), codes=[item.get("code") for item in params.get("diagnostics", [])])
                else:
                    emit("server_message", method=method, id=message.get("id"), params=message.get("params"))
                if "id" in message and process.poll() is None:
                    if method == "workspace/configuration":
                        result = [{} for _ in message.get("params", {}).get("items", [])]
                    else:
                        result = None
                    send({"id": message["id"], "result": result})
            else:
                result = message.get("result")
                items = result.get("items", []) if isinstance(result, dict) else result if isinstance(result, list) else []
                emit("response", id=message.get("id"), error=message.get("error"),
                     result_type=type(result).__name__, labels=[item.get("label") for item in items[:60]],
                     read_present=any(item.get("label") == "Read" for item in items), reader_error=message.get("reader_error"))
            return message

        try:
            send({"id": 0, "method": "initialize", "params": {
                "processId": os.getpid(), "rootUri": root.as_uri(),
                "workspaceFolders": [{"uri": root.as_uri(), "name": "fixture"}],
                "capabilities": {"workspace": {"configuration": True}, "experimental": {"serverStatusNotification": True},
                                 "textDocument": {"completion": {"completionItem": {"snippetSupport": True}}}},
                "initializationOptions": {"checkOnSave": True, "serverPath": "rust-analyzer"}}})
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                response = receive(max(0.1, deadline - time.monotonic()))
                if response.get("id") == 0 and "result" in response:
                    break
            else:
                raise RuntimeError("Server initialization did not finish")
            send({"method": "initialized", "params": {}})
            send({"method": "textDocument/didOpen", "params": {"textDocument": {
                "uri": uri, "languageId": "rust", "version": 1, "text": text}}})
            # Match the GUI probe's 45-second analysis interval while recording all responses.
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                try:
                    receive(min(0.5, max(0.1, deadline - time.monotonic())))
                except queue.Empty:
                    pass
            for request_id, character in ((14, 13), (15, 15)):
                send({"id": request_id, "method": "textDocument/completion", "params": {
                    "position": {"character": character, "line": 0}, "textDocument": {"uri": uri}}})
            responses = {}
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline and len(responses) < 2:
                try:
                    response = receive(min(0.5, max(0.1, deadline - time.monotonic())))
                except queue.Empty:
                    continue
                if response.get("id") in (14, 15) and ("result" in response or "error" in response):
                    responses[response["id"]] = response
            emit("diagnostic_summary", response_ids=sorted(responses), missing_response_ids=sorted({14, 15} - set(responses)),
                 gui_completion_acceptance=False)
        finally:
            emit("teardown_start")
            if process.poll() is None:
                try:
                    send({"id": 99, "method": "shutdown", "params": None})
                    shutdown_received = False
                    deadline = time.monotonic() + 5
                    while time.monotonic() < deadline:
                        try:
                            response = receive(min(0.5, max(0.1, deadline - time.monotonic())))
                        except queue.Empty:
                            continue
                        if response.get("id") == 99 and ("result" in response or "error" in response):
                            shutdown_received = True
                            break
                    if not shutdown_received:
                        emit("shutdown_timeout")
                        raise subprocess.TimeoutExpired("rust-analyzer shutdown response", 5)
                    send({"method": "exit", "params": None})
                    process.wait(timeout=5)
                except (OSError, subprocess.TimeoutExpired):
                    process.kill()
                    process.wait(timeout=5)
            stdout_thread.join(timeout=2)
            stderr_thread.join(timeout=2)
            while True:
                try:
                    receive(0)
                except queue.Empty:
                    break
            emit("server_exit", code=process.returncode, stderr=stderr[-20:],
                 readers_complete=not stdout_thread.is_alive() and not stderr_thread.is_alive())


if __name__ == "__main__":
    main()
