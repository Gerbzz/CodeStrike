"""Bounded, disposable LSP final-state matrix for the isolated v3 experiment."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("rapid", HERE / "rapid-final-state.py")
rapid = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(rapid)
matched = rapid.matched
probe = rapid.probe

SCENARIOS = (
    "final_invalid_priming", "final_valid_priming",
    "alternating_final_valid", "alternating_final_invalid",
    "multi_file", "workspace_reload", "new_file_reload",
    "enable_build", "enable_proc",
)
DISTINCT_INVALID = (
    'use std::io::Read;\nfn main() { let value: i32 = true; println!("{value}"); }'
)


class MultiClient(probe.Client):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.all_diagnostics = []
        self.all_progress = []

    def _handle(self, message, source_uri):
        if message.get("method") == "$/progress":
            params = message.get("params", {})
            value = params.get("value", {})
            if isinstance(value, dict) and value.get("kind") in ("begin", "end"):
                self.all_progress.append({
                    "t_ms": round((time.monotonic() - self.started) * 1000),
                    "token": str(params.get("token"))[:100],
                    "kind": value["kind"],
                })
        if message.get("method") == "textDocument/publishDiagnostics":
            params = message.get("params", {})
            self.all_diagnostics.append({
                "t_ms": round((time.monotonic() - self.started) * 1000),
                "uri": params.get("uri", ""), "version": params.get("version"),
                "codes": [item.get("code") for item in params.get("diagnostics", [])],
                "messages": [str(item.get("message", ""))[:120]
                             for item in params.get("diagnostics", [])],
                "details": params.get("diagnostics", []),
            })
        super()._handle(message, source_uri)


def options(build, proc):
    return rapid.options(build, proc)


def passive(client, uri, seconds):
    try:
        client.wait_for(lambda _: False, uri, seconds, "passive hold")
    except TimeoutError:
        pass


def wait_diag(client, primary_uri, target_uri, version, error, seconds):
    if any(
        item["uri"].casefold() == target_uri.casefold()
        and item["version"] == version
        and ("E0308" in item["codes"]) == error
        for item in client.all_diagnostics
    ):
        return True
    expected = lambda msg: probe.diag_at(msg, target_uri, version, error)
    try:
        client.wait_for(expected, primary_uri, seconds, "initial diagnostic")
    except TimeoutError:
        return False
    return True


def next_id(counter):
    counter[0] += 1
    return counter[0]


def request(client, primary_uri, method, params, counter, seconds=12):
    return matched.request(
        client, primary_uri, method, params, next_id(counter), seconds
    )


def exact(client, primary_uri, path, uri, text, counter):
    return matched.exact_text(client, path, uri, next_id(counter), text)


def edit(client, path, uri, version, text):
    matched.edit(client, path, uri, version, text)
    return {
        "uri": uri, "version": version,
        "sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "bytes": len(text.encode("utf-8")),
        "t_ms": round((time.monotonic() - client.started) * 1000),
    }


def final_check(client, uri, version, text, error, exact_text):
    def correct(item):
        if item["version"] != version:
            return False
        if not error:
            return not item["codes"]
        if "E0308" not in item["codes"]:
            return False
        if "= true" in text:
            return any("found bool" in message for message in item["messages"])
        return True

    records = [
        item for item in client.all_diagnostics
        if item["uri"].casefold() == uri.casefold()
    ]
    matching = [
        index for index, item in enumerate(records)
        if correct(item)
    ]
    first_correct = matching[0] if matching else None
    after_correct = records[first_correct:] if first_correct is not None else []
    no_late_stale = bool(matching) and all(
        correct(item)
        for item in after_correct
    )
    latest = records[-1] if records else None
    return {
        "uri": uri, "version": version, "expected_e0308": error,
        "text_sha256": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "server_and_disk_exact": exact_text,
        "last_publication": latest,
        "latest_correct": bool(latest) and correct(latest),
        "no_late_stale_restoration": no_late_stale,
        "publications": records[-20:],
    }


def run(scenario, binary, patch_file, base, hold):
    root, source = probe.make_fixture(base)
    secondary = root / "src" / ("new.rs" if scenario == "new_file_reload" else "other.rs")
    main_invalid = probe.INVALID
    main_valid = probe.VALID
    if scenario == "multi_file":
        main_invalid = "mod other;\n" + main_invalid
        main_valid = "mod other;\n" + main_valid
        source.write_bytes(main_invalid.encode("utf-8"))
        secondary.write_bytes(b'pub fn other() { let value: i32 = "wrong"; }\n')
    elif scenario == "new_file_reload":
        prefix = "".join(f"mod helper_{index};\n" for index in range(24))
        for index in range(24):
            (root / "src" / f"helper_{index}.rs").write_text(
                f"pub fn helper_{index}() -> i32 {{ {index} }}\n", encoding="utf-8"
            )
        main_invalid = prefix + main_invalid
        main_valid = prefix + main_valid
        source.write_bytes(main_invalid.encode("utf-8"))
    subprocess.run(
        ["cargo", "generate-lockfile", "--offline", "--manifest-path",
         str(root / "Cargo.toml")],
        check=True, capture_output=True, text=True,
    )
    safe_temp = base / "analyzer-temp"
    safe_temp.mkdir()
    rust_src = Path(os.environ["RUST_SRC_PATH"])
    if not (rust_src / "core" / "src" / "lib.rs").is_file():
        raise RuntimeError("compiler-matched isolated rust-src unavailable")

    reload_scenario = scenario in ("workspace_reload", "new_file_reload")
    initial = options(reload_scenario, reload_scenario)
    changed = options(
        scenario in ("enable_build", "workspace_reload", "new_file_reload"),
        scenario not in ("enable_build", "workspace_reload", "new_file_reload"),
    )
    old_env = {key: os.environ.get(key) for key in ("TEMP", "TMP", "RUST_SRC_PATH")}
    os.environ["TEMP"] = str(safe_temp)
    os.environ["TMP"] = str(safe_temp)
    os.environ["RUST_SRC_PATH"] = str(rust_src)
    try:
        client = MultiClient(
            [str(binary)], root, time.monotonic() + hold + 180, scenario,
        )
    finally:
        for key, value in old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

    uri = source.as_uri()
    other_uri = secondary.as_uri()
    root_uri = root.as_uri() + "/"
    counter = [5000]
    result = {
        "scenario": scenario, "source_head": "a0b58c0fe3e924302c1155e88c4a9454f86280c2",
        "patch_sha256": hashlib.sha256(patch_file.read_bytes()).hexdigest().upper(),
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest().upper(),
        "binary_version": probe.analyzer_version(str(binary), None),
        "hold_seconds": hold, "initial_options": initial,
    }
    expected = []
    try:
        request(client, uri, "initialize", {
            "processId": os.getpid(),
            "clientInfo": {"name": "Isolated analyzer final-state matrix", "version": "1"},
            "rootUri": root_uri, "rootPath": str(root),
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
        }, counter, 35)
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "rust", "version": 1,
                             "text": main_invalid},
        })
        if scenario == "multi_file":
            client.send("textDocument/didOpen", {
                "textDocument": {
                    "uri": other_uri, "languageId": "rust", "version": 1,
                    "text": secondary.read_text(encoding="utf-8"),
                },
            })
        result["initial_ready"] = rapid.wait_workspace(client, root, uri)
        result["initial_main_error"] = wait_diag(client, uri, uri, 1, True, 20)
        if scenario == "multi_file":
            result["initial_other_error"] = wait_diag(
                client, uri, other_uri, 1, True, 20
            )
        result["queues_before"] = {
            "build": matched.progress_count(client, "Building compile-time-deps"),
            "proc": matched.progress_count(client, "Loading proc-macros"),
            "fetch": matched.progress_count(client, "rustAnalyzer/Fetching"),
        }

        if reload_scenario:
            request(client, uri, "rust-analyzer/reloadWorkspace", None, counter)
            result["transition"] = "rust-analyzer/reloadWorkspace"
            result["reload_request_t_ms"] = round(
                (time.monotonic() - client.started) * 1000
            )
            if scenario == "new_file_reload":
                client.wait_for(
                    lambda msg: msg.get("method") == "$/progress"
                    and msg.get("params", {}).get("value", {}).get("kind") == "begin"
                    and "cachePriming" in str(msg.get("params", {}).get("token")),
                    uri, 40, "reload cache-priming begin",
                )
                result["priming_begin_observed"] = True
        else:
            client.configuration_reply = changed
            client.send("workspace/didChangeConfiguration", {"settings": changed})
            client.wait_for(
                lambda msg: msg.get("method") == "workspace/configuration"
                and "id" in msg, uri, 12, "configuration request",
            )
            result["transition"] = "workspace/didChangeConfiguration"
            result["changed_options"] = changed
            result["configuration_requests"] = client.configuration_requests

        edits = []
        if scenario in ("final_invalid_priming", "enable_build", "enable_proc", "workspace_reload"):
            edits.append(edit(client, source, uri, 2, main_valid))
            final = DISTINCT_INVALID + "\n// final invalid v3\n"
            edits.append(edit(client, source, uri, 3, final))
            expected.append((source, uri, 3, final, True))
        elif scenario == "final_valid_priming":
            final = main_valid + "\n// final valid v2\n"
            edits.append(edit(client, source, uri, 2, final))
            expected.append((source, uri, 2, final, False))
        elif scenario in ("alternating_final_valid", "alternating_final_invalid"):
            last = 6 if scenario == "alternating_final_valid" else 5
            for version in range(2, last + 1):
                text = (main_valid if version % 2 == 0 else DISTINCT_INVALID)
                text += f"\n// alternating v{version}\n"
                edits.append(edit(client, source, uri, version, text))
            expected.append((source, uri, last, text, last % 2 != 0))
        elif scenario == "multi_file":
            other_valid = "pub fn other() { let value: i32 = 7; }\n"
            other_invalid = 'pub fn other() { let value: i32 = true; }\n// final other v3\n'
            final_main = main_valid + "\n// final main v2\n"
            edits.append(edit(client, source, uri, 2, final_main))
            edits.append(edit(client, secondary, other_uri, 2, other_valid))
            edits.append(edit(client, secondary, other_uri, 3, other_invalid))
            expected.extend([
                (source, uri, 2, final_main, False),
                (secondary, other_uri, 3, other_invalid, True),
            ])
        elif scenario == "new_file_reload":
            new_text = 'pub fn new_fn() { let value: i32 = true; }\n'
            secondary.write_bytes(new_text.encode("utf-8"))
            final_main = "mod new;\n" + main_valid + "\n// final with new module\n"
            edits.append(edit(client, source, uri, 2, final_main))
            result["new_file_open_t_ms"] = round(
                (time.monotonic() - client.started) * 1000
            )
            client.send("textDocument/didOpen", {
                "textDocument": {"uri": secondary.as_uri(), "languageId": "rust",
                                 "version": 1, "text": new_text},
            })
            expected.extend([
                (source, uri, 2, final_main, False),
                (secondary, other_uri, 1, new_text, True),
            ])
        result["edits"] = edits
        result["queues_after_edits"] = {
            "build": matched.progress_count(client, "Building compile-time-deps"),
            "proc": matched.progress_count(client, "Loading proc-macros"),
            "fetch": matched.progress_count(client, "rustAnalyzer/Fetching"),
        }
        passive(client, uri, hold)
        result["queues_after_hold"] = {
            "build": matched.progress_count(client, "Building compile-time-deps"),
            "proc": matched.progress_count(client, "Loading proc-macros"),
            "fetch": matched.progress_count(client, "rustAnalyzer/Fetching"),
        }
        status = request(client, uri, "rust-analyzer/analyzerStatus",
                         {"textDocument": {"uri": uri}}, counter)
        result["workspace_status"] = probe.summarize_analyzer_status(status, root)
        exact_texts = [
            exact(client, uri, path, doc_uri, text, counter)
            for path, doc_uri, version, text, error in expected
        ]
        passive(client, uri, 3)  # catch late publication after status/text requests
        result["final_checks"] = [
            final_check(client, doc_uri, version, text, error, exact_texts[index])
            for index, (path, doc_uri, version, text, error) in enumerate(expected)
        ]
        result["quiescent"] = bool(
            client.server_status and client.server_status[-1]["quiescent"] is True
        )
        result["diagnostics_total"] = len(client.all_diagnostics)
        result["diagnostics_all"] = client.all_diagnostics[-40:]
        if scenario == "new_file_reload":
            result["priming_after_new_file"] = any(
                item["kind"] == "end" and "cachePriming" in item["token"]
                and item["t_ms"] >= result["new_file_open_t_ms"]
                for item in client.all_progress
            )
            result["priming_progress"] = [
                item for item in client.all_progress
                if "cachePriming" in item["token"]
            ][-8:]
    finally:
        client.close(uri)
        result["shutdown_reply"] = client.shutdown_reply_seen

    initial_ok = result.get("initial_main_error") and (
        scenario != "multi_file" or result.get("initial_other_error")
    )
    queue_kind = "fetch" if scenario in ("workspace_reload", "new_file_reload") else (
        "build" if scenario == "enable_build" else "proc"
    )
    queue_ok = (result["queues_after_hold"][queue_kind]
                > result["queues_before"][queue_kind])
    if scenario in ("enable_proc", "multi_file", "final_invalid_priming",
                    "final_valid_priming", "alternating_final_valid",
                    "alternating_final_invalid"):
        queue_ok = queue_ok and (
            result["queues_after_hold"]["proc"] > result["queues_before"]["proc"]
        )
    result["pass"] = bool(
        initial_ok and queue_ok and result["quiescent"]
        and result["shutdown_reply"]
        and (scenario != "new_file_reload"
             or (result.get("priming_begin_observed")
                 and result.get("priming_after_new_file")))
        and all(check["server_and_disk_exact"] and check["latest_correct"]
                and check["no_late_stale_restoration"]
                for check in result["final_checks"])
    )
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", choices=SCENARIOS)
    parser.add_argument("binary", type=Path)
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("--patch", type=Path, required=True)
    parser.add_argument("--hold-seconds", type=int, default=15)
    args = parser.parse_args()
    base = args.fixture_directory.resolve()
    base.mkdir(parents=True, exist_ok=False)
    try:
        result = run(args.scenario, args.binary.resolve(), args.patch.resolve(),
                     base, args.hold_seconds)
    except Exception as exc:
        result = {"scenario": args.scenario, "pass": False,
                  "error": str(exc)[:300]}
    print("V3_FINAL_STATE_MATRIX=" + json.dumps(result, separators=(",", ":")))
    return 0 if result["pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
