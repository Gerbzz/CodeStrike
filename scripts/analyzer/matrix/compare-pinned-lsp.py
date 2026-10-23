"""Matched, bounded LSP fixture for exact-source baseline/candidate binaries.

Uses the CodeStrike PR's existing LSP transport and a disposable Cargo project.
No CodeStrike application source or user settings are loaded.
"""

import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "codestrike_standalone_probe", HERE / "probe-standalone-rust-analyzer.py"
)
probe = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(probe)


def observed(client, version, has_error):
    return any(
        item["version"] == version
        and ("E0308" in item["codes"]) == has_error
        for item in client.diagnostics
    )


def wait_diagnostic(client, uri, version, has_error, seconds):
    if observed(client, version, has_error):
        return True
    try:
        client.wait_for(
            lambda msg: probe.diag_at(msg, uri, version, has_error),
            uri, seconds, f"v{version} E0308={has_error}"
        )
    except TimeoutError:
        return False
    return observed(client, version, has_error)


def request(client, uri, method, params, request_id, seconds=12):
    client.send(method, params, request_id=request_id)
    reply = client.wait_for(
        lambda msg: probe.is_reply(msg, request_id), uri, seconds, method
    )
    if "error" in reply:
        raise RuntimeError(f"{method}: {str(reply['error'])[:160]}")
    return reply.get("result")


def exact_text(client, source, uri, request_id, expected):
    result = request(
        client, uri, "rust-analyzer/viewFileText", {"uri": uri}, request_id
    )
    return result == expected and source.read_bytes() == expected.encode("utf-8")


def edit(client, source, uri, version, text):
    source.write_bytes(text.encode("utf-8"))
    client.send("textDocument/didChange", {
        "textDocument": {"uri": uri, "version": version},
        "contentChanges": [{"text": text}],
    })


def progress_count(client, name):
    return sum(
        item["kind"] == "end" and name in item["token"]
        for item in client.progress
    )


def wait_readiness(client, root, uri, require_build_count=None):
    deadline = time.monotonic() + 80
    request_id = 100
    while time.monotonic() < deadline:
        try:
            status = request(
                client, uri, "rust-analyzer/analyzerStatus",
                {"textDocument": {"uri": uri}}, request_id, 8
            )
        except TimeoutError:
            request_id += 1
            continue
        summary = probe.summarize_analyzer_status(status, root)
        quiescent = bool(
            client.server_status and client.server_status[-1]["quiescent"] is True
        )
        build_count = progress_count(client, "Building compile-time-deps")
        proc_count = progress_count(client, "Loading proc-macros")
        if (
            summary.get("loaded")
            and summary.get("workspace_root_mentions_fixture")
            and quiescent
            and build_count >= (require_build_count or 1)
            and proc_count >= 1
        ):
            return {
                "loaded": summary["loaded"],
                "quiescent": quiescent,
                "build_ends": build_count,
                "proc_ends": proc_count,
                "ready_t_ms": round((time.monotonic() - client.started) * 1000),
                "status_excerpt": status[:1200],
                "warning_excerpt": (
                    status[status.index("Failed to read Cargo metadata"):
                           status.index("Failed to read Cargo metadata") + 500]
                    if "Failed to read Cargo metadata" in status else ""
                ),
            }
        request_id += 1
        time.sleep(0.25)
    raise TimeoutError("common workspace/build/proc readiness barrier")


def completion_labels(value):
    if isinstance(value, list):
        items = value
    elif isinstance(value, dict):
        items = value.get("items", [])
    else:
        items = []
    return [item.get("label") for item in items if isinstance(item, dict)]


def run(binary, case, root_dir, initial_only=False, trace_main_loop=False,
        use_rust_src=True):
    root, source = probe.make_fixture(root_dir)
    subprocess.run(
        ["cargo", "generate-lockfile", "--offline", "--manifest-path",
         str(root / "Cargo.toml")],
        check=True, capture_output=True, text=True,
    )
    uri = source.as_uri()
    root_uri = root.as_uri() + "/"
    safe_temp = root_dir / "analyzer-temp"
    safe_temp.mkdir()
    rust_src = Path(os.environ["RUST_SRC_PATH"])
    if use_rust_src and not (rust_src / "core" / "src" / "lib.rs").is_file():
        raise RuntimeError("matching workspace-local Rust source is unavailable")
    previous_temp = {
        key: os.environ.get(key) for key in ("TEMP", "TMP", "RUST_SRC_PATH")
    }
    os.environ["TEMP"] = str(safe_temp)
    os.environ["TMP"] = str(safe_temp)
    if use_rust_src:
        os.environ["RUST_SRC_PATH"] = str(rust_src)
    else:
        os.environ.pop("RUST_SRC_PATH", None)
    try:
        client = probe.Client(
            [str(binary)], root, time.monotonic() + 230, case,
            trace_main_loop=trace_main_loop,
        )
    finally:
        for key, value in previous_temp.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    result = {"case": case, "binary": str(binary), "version": None}
    result["rust_src_mode"] = "matching-1.97.1" if use_rust_src else "unset"
    try:
        result["version"] = probe.analyzer_version(str(binary), None)
        initialize = request(client, uri, "initialize", {
            "processId": os.getpid(),
            "clientInfo": {"name": "CodeStrike pinned candidate review", "version": "1"},
            "rootUri": root_uri,
            "rootPath": str(root),
            "workspaceFolders": [{"uri": root_uri, "name": root.name}],
            "capabilities": {
                "workspace": {"workspaceFolders": True, "configuration": True},
                "textDocument": {
                    "synchronization": {"dynamicRegistration": False},
                    "publishDiagnostics": {"versionSupport": True},
                    "completion": {"completionItem": {"snippetSupport": False}},
                },
                "window": {"workDoneProgress": True},
                "experimental": {"serverStatusNotification": True},
            },
            "initializationOptions": probe.DEFAULT_OPTIONS,
        }, 1, 35)
        result["diagnostic_provider"] = "diagnosticProvider" in initialize.get(
            "capabilities", {}
        )
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {
                "uri": uri, "languageId": "rust", "version": 1,
                "text": probe.INVALID,
            }
        })
        result["initial_ready"] = wait_readiness(client, root, uri)
        result["initial_v1_e0308"] = wait_diagnostic(client, uri, 1, True, 18)
        if initial_only:
            result["diagnostics"] = [
                {"t_ms": item["t_ms"], "version": item["version"],
                 "codes": item["codes"]}
                for item in client.diagnostics[-12:]
            ]
            result["main_loop_events"] = client.main_loop_events[-50:]
            result["diagnostic_trace_lines"] = client.diagnostic_trace_lines[-35:]
            result["stderr_prefix"] = client.stderr.decode(
                "utf-8", errors="replace"
            )[:1200]
            return result

        edit(client, source, uri, 2, probe.VALID)
        result["valid_v2_exact_text"] = exact_text(
            client, source, uri, 2, probe.VALID
        )
        result["valid_v2_no_e0308"] = wait_diagnostic(
            client, uri, 2, False, 22
        )

        edit(client, source, uri, 3, probe.DISTINCT_INVALID)
        result["invalid_v3_exact_text"] = exact_text(
            client, source, uri, 3, probe.DISTINCT_INVALID
        )
        result["invalid_v3_e0308"] = wait_diagnostic(
            client, uri, 3, True, 22
        )

        old_build_ends = progress_count(client, "Building compile-time-deps")
        request(client, uri, "rust-analyzer/rebuildProcMacros", None, 4)
        edit(client, source, uri, 4, probe.VALID + "\n// valid during reload\n")
        result["reload_valid_v4_exact_text"] = exact_text(
            client, source, uri, 5, probe.VALID + "\n// valid during reload\n"
        )
        result["reload_ready"] = wait_readiness(
            client, root, uri, old_build_ends + 1
        )
        result["reload_valid_v4_no_e0308"] = wait_diagnostic(
            client, uri, 4, False, 22
        )

        invalid_v5 = probe.DISTINCT_INVALID + "// invalid after reload\n"
        edit(client, source, uri, 5, invalid_v5)
        result["reload_invalid_v5_exact_text"] = exact_text(
            client, source, uri, 6, invalid_v5
        )
        result["reload_invalid_v5_e0308"] = wait_diagnostic(
            client, uri, 5, True, 22
        )

        completion_text = (
            "mod fixture_io { pub struct Read; }\n"
            "use fixture_io::Re;\n"
            "fn main() {}\n"
        )
        edit(client, source, uri, 6, completion_text)
        result["completion_v6_exact_text"] = exact_text(
            client, source, uri, 7, completion_text
        )
        completion = request(client, uri, "textDocument/completion", {
            "textDocument": {"uri": uri},
            "position": {"line": 1, "character": len("use fixture_io::Re")},
            "context": {"triggerKind": 1},
        }, 8, 18)
        labels = completion_labels(completion)
        result["completion_read"] = "Read" in labels
        result["completion_label_count"] = len(labels)
        result["completion_labels_sample"] = labels[:12]
        result["diagnostics"] = [
            {"version": item["version"], "codes": item["codes"]}
            for item in client.diagnostics[-16:]
        ]
        result["shutdown_reply"] = None
    finally:
        client.close(uri)
        result["shutdown_reply"] = client.shutdown_reply_seen
        result["server_requests_sample"] = client.requests[-12:]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=("baseline", "candidate"))
    parser.add_argument("--initial-only", action="store_true")
    parser.add_argument("--trace-main-loop", action="store_true")
    parser.add_argument("--no-rust-src", action="store_true")
    parser.add_argument("binary", type=Path)
    parser.add_argument("fixture_directory", type=Path)
    args = parser.parse_args()
    args.fixture_directory = args.fixture_directory.resolve()
    args.fixture_directory.mkdir(parents=True, exist_ok=False)
    try:
        result = run(
            args.binary.resolve(), args.case, args.fixture_directory,
            initial_only=args.initial_only,
            trace_main_loop=args.trace_main_loop,
            use_rust_src=not args.no_rust_src,
        )
    except Exception as exc:
        result = {"case": args.case, "error": str(exc)[:240]}
    print("PINNED_LSP_COMPARISON=" + json.dumps(result, separators=(",", ":")))
    return 0 if "error" not in result else 1


if __name__ == "__main__":
    raise SystemExit(main())
