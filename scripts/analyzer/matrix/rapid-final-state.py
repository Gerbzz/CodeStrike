"""Hold a rapid final invalid edit to distinguish coalescing from stale state."""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "matched_probe", HERE / "compare-pinned-lsp.py"
)
matched = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matched)
probe = matched.probe


def options(build_scripts, proc_macros):
    return {
        "checkOnSave": False,
        "serverPath": "rust-analyzer",
        "cargo": {"buildScripts": {"enable": build_scripts}},
        "procMacro": {"enable": proc_macros},
    }


def wait_workspace(client, root, uri):
    deadline = time.monotonic() + 80
    request_id = 100
    while time.monotonic() < deadline:
        try:
            status = matched.request(
                client, uri, "rust-analyzer/analyzerStatus",
                {"textDocument": {"uri": uri}}, request_id, 8,
            )
        except TimeoutError:
            request_id += 1
            continue
        summary = probe.summarize_analyzer_status(status, root)
        quiescent = bool(
            client.server_status and client.server_status[-1]["quiescent"] is True
        )
        if (
            summary.get("loaded")
            and summary.get("workspace_root_mentions_fixture")
            and quiescent
        ):
            return {
                "loaded": summary["loaded"],
                "quiescent": True,
                "t_ms": round((time.monotonic() - client.started) * 1000),
            }
        request_id += 1
        time.sleep(0.25)
    raise TimeoutError("disabled-initialization workspace readiness")


def config_lines(status):
    text = status.split("Configuration: \n", 1)[-1]
    return [
        line.strip()[:160] for line in text.splitlines()
        if "buildScripts" in line or "procMacro" in line
    ][:12]


def wait_rebuild(client, root, uri, old_build, old_proc, require_proc):
    deadline = time.monotonic() + 80
    request_id = 110
    while time.monotonic() < deadline:
        status = matched.request(
            client, uri, "rust-analyzer/analyzerStatus",
            {"textDocument": {"uri": uri}}, request_id, 12,
        )
        summary = probe.summarize_analyzer_status(status, root)
        build = matched.progress_count(client, "Building compile-time-deps")
        proc = matched.progress_count(client, "Loading proc-macros")
        quiescent = bool(
            client.server_status and client.server_status[-1]["quiescent"] is True
        )
        if (summary.get("loaded") and quiescent and build > old_build
                and (not require_proc or proc > old_proc)):
            return {"loaded": summary["loaded"], "quiescent": True,
                    "build_ends": build, "proc_ends": proc,
                    "t_ms": round((time.monotonic() - client.started) * 1000)}
        request_id += 1
        time.sleep(0.25)
    raise TimeoutError("build/proc reload readiness")


def run(binary, case, mode, base, hold_seconds=60, trace_main_loop=True):
    root, source = probe.make_fixture(base)
    subprocess.run(
        ["cargo", "generate-lockfile", "--offline", "--manifest-path",
         str(root / "Cargo.toml")],
        check=True, capture_output=True, text=True,
    )
    safe_temp = base / "analyzer-temp"
    safe_temp.mkdir()
    rust_src = Path(os.environ["RUST_SRC_PATH"])
    if not (rust_src / "core" / "src" / "lib.rs").is_file():
        raise RuntimeError("matching isolated Rust source unavailable")
    previous = {
        key: os.environ.get(key) for key in ("TEMP", "TMP", "RUST_SRC_PATH")
    }
    os.environ["TEMP"] = str(safe_temp)
    os.environ["TMP"] = str(safe_temp)
    os.environ["RUST_SRC_PATH"] = str(rust_src)
    try:
        client = probe.Client(
            [str(binary)], root, time.monotonic() + hold_seconds + 150, case,
            trace_main_loop=trace_main_loop,
        )
    finally:
        for key, value in previous.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    uri = source.as_uri()
    root_uri = root.as_uri() + "/"
    initial = options(False, False)
    changed = options(mode == "build", mode == "proc")
    result = {
        "case": case, "mode": mode,
        "hold_seconds": hold_seconds,
        "binary_version": probe.analyzer_version(str(binary), None),
        "initial_options": initial, "changed_options": changed,
    }
    try:
        matched.request(client, uri, "initialize", {
            "processId": os.getpid(),
            "clientInfo": {"name": "CodeStrike queue toggle review", "version": "1"},
            "rootUri": root_uri,
            "rootPath": str(root),
            "workspaceFolders": [{"uri": root_uri, "name": root.name}],
            "capabilities": {
                "workspace": {"workspaceFolders": True, "configuration": True},
                "textDocument": {
                    "synchronization": {"dynamicRegistration": False},
                    "publishDiagnostics": {"versionSupport": True},
                },
                "window": {"workDoneProgress": True},
                "experimental": {"serverStatusNotification": True},
            },
            "initializationOptions": initial,
        }, 1, 35)
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {
                "uri": uri, "languageId": "rust", "version": 1,
                "text": probe.INVALID,
            }
        })
        result["initial_ready"] = wait_workspace(client, root, uri)
        result["initial_v1_e0308"] = matched.wait_diagnostic(
            client, uri, 1, True, 20
        )
        before_build = matched.progress_count(
            client, "Building compile-time-deps"
        )
        before_proc = matched.progress_count(client, "Loading proc-macros")
        result["queue_ends_before"] = {
            "build": before_build, "proc": before_proc,
        }
        client.configuration_reply = changed
        client.send("workspace/didChangeConfiguration", {"settings": changed})
        client.wait_for(
            lambda msg: msg.get("method") == "workspace/configuration"
            and "id" in msg, uri, 12, "configuration request",
        )
        result["configuration_requests"] = client.configuration_requests
        status = matched.request(
            client, uri, "rust-analyzer/analyzerStatus",
            {"textDocument": {"uri": uri}}, 2, 12,
        )
        result["configuration_lines"] = config_lines(status)

        matched.edit(client, source, uri, 2, probe.VALID)
        result["valid_v2_exact_text"] = matched.exact_text(
            client, source, uri, 3, probe.VALID
        )
        result["valid_v2_no_e0308"] = matched.wait_diagnostic(
            client, uri, 2, False, 25
        )

        result["v3_send_t_ms"] = round((time.monotonic() - client.started) * 1000)
        matched.edit(client, source, uri, 3, probe.DISTINCT_INVALID)
        result["invalid_v3_exact_text"] = matched.exact_text(
            client, source, uri, 4, probe.DISTINCT_INVALID
        )
        # Do not send another edit or request during this passive hold. The
        # latest document remains exact v3 even if intermediate versions were
        # legitimately coalesced by the server.
        try:
            client.wait_for(lambda _message: False, uri, hold_seconds,
                            "passive final-state hold")
        except TimeoutError:
            pass
        result["passive_v3_e0308"] = matched.observed(client, 3, True)
        result["passive_v3_publications"] = [
            {"t_ms": item["t_ms"], "codes": item["codes"]}
            for item in client.diagnostics if item["version"] == 3
        ]
        result["queue_ends_after_hold"] = {
            "build": matched.progress_count(client, "Building compile-time-deps"),
            "proc": matched.progress_count(client, "Loading proc-macros"),
        }
        status = matched.request(
            client, uri, "rust-analyzer/analyzerStatus",
            {"textDocument": {"uri": uri}}, 5, 12,
        )
        result["final_workspace_status"] = probe.summarize_analyzer_status(status, root)
        result["final_server_and_disk_exact_v3"] = matched.exact_text(
            client, source, uri, 6, probe.DISTINCT_INVALID
        )
        result["last_published_version"] = (
            client.diagnostics[-1]["version"] if client.diagnostics else None
        )
        result["final_server_quiescent"] = bool(
            client.server_status and client.server_status[-1]["quiescent"] is True
        )
        result["diagnostics"] = [
            {"t_ms": item["t_ms"], "version": item["version"],
             "codes": item["codes"]}
            for item in client.diagnostics[-15:]
        ]
        result["status_last"] = client.server_status[-1] if client.server_status else None
        if trace_main_loop:
            result["main_loop_events"] = client.main_loop_events[-80:]
        result["diagnostic_trace_lines"] = client.diagnostic_trace_lines[-150:]
    finally:
        client.close(uri)
        result["shutdown_reply"] = client.shutdown_reply_seen
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=("baseline", "candidate"))
    parser.add_argument("mode", choices=("build", "proc"))
    parser.add_argument("binary", type=Path)
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("--assert-final", action="store_true")
    parser.add_argument("--hold-seconds", type=int, default=60)
    parser.add_argument("--no-trace", action="store_true")
    args = parser.parse_args()
    base = args.fixture_directory.resolve()
    base.mkdir(parents=True, exist_ok=False)
    try:
        result = run(
            args.binary.resolve(), args.case, args.mode, base,
            hold_seconds=args.hold_seconds,
            trace_main_loop=not args.no_trace,
        )
    except Exception as exc:
        result = {"case": args.case, "mode": args.mode,
                  "error": str(exc)[:240]}
    print("PINNED_TOGGLE_COMPARISON=" + json.dumps(result, separators=(",", ":")))
    if "error" in result:
        return 1
    if args.assert_final:
        if not result["initial_v1_e0308"]:
            return 3  # no prior error: valid-clearance gate is inconclusive
        required = (
            "valid_v2_exact_text", "valid_v2_no_e0308",
            "invalid_v3_exact_text", "final_server_and_disk_exact_v3",
            "passive_v3_e0308", "final_server_quiescent", "shutdown_reply",
        )
        return 0 if all(result[key] for key in required) else 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
