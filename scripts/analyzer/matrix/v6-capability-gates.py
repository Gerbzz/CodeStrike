"""Bounded pull and disabled-diagnostics gates for the isolated analyzer binary."""

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("matrix", HERE / "v3-final-state-matrix.py")
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)
rapid = matrix.rapid
probe = matrix.probe


class Client(matrix.MultiClient):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.refresh_requests = 0

    def _handle(self, message, source_uri):
        if message.get("method") == "workspace/diagnostic/refresh" and "id" in message:
            self.refresh_requests += 1
            probe.write_frame(self.process.stdin, {
                "jsonrpc": "2.0", "id": message["id"], "result": None,
            })
            return
        super()._handle(message, source_uri)


def codes(report):
    if not isinstance(report, dict):
        return []
    nested = report.get("relatedDocuments") or {}
    return [item.get("code") for item in report.get("items", [])] + [
        item.get("code") for entry in nested.values()
        for item in entry.get("items", [])
    ]


def messages(report):
    return [str(item.get("message", ""))[:120] for item in report.get("items", [])]


def run(mode, binary, patch, base):
    root, source = probe.make_fixture(base)
    subprocess.run(["cargo", "generate-lockfile", "--offline", "--manifest-path",
                    str(root / "Cargo.toml")], check=True, capture_output=True, text=True)
    safe_temp = base / "analyzer-temp"
    safe_temp.mkdir()
    rust_src = Path(os.environ["RUST_SRC_PATH"])
    if not (rust_src / "core" / "src" / "lib.rs").is_file():
        raise RuntimeError("compiler-matched rust-src unavailable")
    old_env = {key: os.environ.get(key) for key in ("TEMP", "TMP", "RUST_SRC_PATH")}
    os.environ.update({"TEMP": str(safe_temp), "TMP": str(safe_temp),
                       "RUST_SRC_PATH": str(rust_src)})
    try:
        client = Client([str(binary)], root, time.monotonic() + 170, mode)
    finally:
        for key, value in old_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    uri = source.as_uri()
    root_uri = root.as_uri() + "/"
    pull = mode in ("pull", "disabled_pull")
    disabled = mode in ("disabled_push", "disabled_pull")
    options = rapid.options(False, False)
    if disabled:
        options["diagnostics"] = {"enable": False}
    capabilities = {
        "workspace": {"workspaceFolders": True, "configuration": True},
        "textDocument": {"synchronization": {"dynamicRegistration": False}},
        "window": {"workDoneProgress": True},
        "experimental": {"serverStatusNotification": True},
    }
    if pull:
        capabilities["textDocument"]["diagnostic"] = {
            "dynamicRegistration": False, "relatedDocumentSupport": False,
        }
        capabilities["workspace"]["diagnostics"] = {"refreshSupport": True}
    else:
        capabilities["textDocument"]["publishDiagnostics"] = {"versionSupport": True}
    result = {
        "mode": mode, "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest().upper(),
        "patch_sha256": hashlib.sha256(patch.read_bytes()).hexdigest().upper(),
        "binary_version": probe.analyzer_version(str(binary), None),
        "initial_options": options,
    }
    counter = [8000]
    try:
        matrix.request(client, uri, "initialize", {
            "processId": os.getpid(), "clientInfo": {"name": "Isolated diagnostic capability gate"},
            "rootUri": root_uri, "rootPath": str(root),
            "workspaceFolders": [{"uri": root_uri, "name": root.name}],
            "capabilities": capabilities, "initializationOptions": options,
        }, counter, 35)
        client.send("initialized", {})
        client.send("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "rust", "version": 1,
                             "text": probe.INVALID},
        })
        result["ready"] = rapid.wait_workspace(client, root, uri)
        def pull_report():
            return matrix.request(client, uri, "textDocument/diagnostic", {
                "textDocument": {"uri": uri}, "identifier": None,
                "previousResultId": None,
            }, counter, 20)
        reports = []
        if pull:
            reports.append(pull_report())
        valid = probe.VALID + "\n// capability v2\n"
        invalid = matrix.DISTINCT_INVALID + "\n// capability v3\n"
        matrix.edit(client, source, uri, 2, valid)
        matrix.passive(client, uri, 2)
        if pull:
            reports.append(pull_report())
        matrix.edit(client, source, uri, 3, invalid)
        matrix.passive(client, uri, 2)
        if pull:
            reports.append(pull_report())
        matrix.passive(client, uri, 15)
        result["server_and_disk_exact"] = matrix.exact(
            client, uri, source, uri, invalid, counter)
        matrix.passive(client, uri, 3)
        if pull:
            reports.append(pull_report())
            matrix.passive(client, uri, 2)
        result["pull_reports"] = [
            {"kind": entry.get("kind"), "codes": codes(entry), "messages": messages(entry)}
            for entry in reports
        ]
        result["push_publications"] = client.all_diagnostics
        result["refresh_requests"] = client.refresh_requests
        result["quiescent"] = bool(
            client.server_status and client.server_status[-1]["quiescent"] is True)
    finally:
        client.close(uri)
        result["shutdown_reply"] = client.shutdown_reply_seen
    if pull and not disabled:
        expected = (
            len(result["pull_reports"]) == 4
            and result["pull_reports"][0]["codes"] == ["E0308"]
            and not result["pull_reports"][1]["codes"]
            and not result["pull_reports"][1]["messages"]
            and result["pull_reports"][2]["codes"] == ["E0308"]
            and any("found bool" in item for item in result["pull_reports"][2]["messages"])
            and result["pull_reports"][3]["codes"] == ["E0308"]
            and any("found bool" in item for item in result["pull_reports"][3]["messages"])
        )
    elif pull:
        expected = len(result["pull_reports"]) == 4 and all(
            not report["codes"] and not report["messages"] for report in result["pull_reports"])
    else:
        expected = not any(item["codes"] for item in result["push_publications"])
    result["pass"] = bool(
        expected and result["server_and_disk_exact"] and result["quiescent"]
        and result["shutdown_reply"] and len(result["push_publications"]) <= 8
        and result["refresh_requests"] <= 8
        and (not pull or not result["push_publications"])
    )
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=("pull", "disabled_push", "disabled_pull"))
    parser.add_argument("binary", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("fixture_directory", type=Path)
    args = parser.parse_args()
    base = args.fixture_directory.resolve()
    base.mkdir(parents=True, exist_ok=False)
    try:
        result = run(args.mode, args.binary.resolve(), args.patch.resolve(), base)
    except Exception as exc:
        result = {"mode": args.mode, "pass": False, "error": str(exc)[:300]}
    print("V6_CAPABILITY_GATE=" + json.dumps(result, separators=(",", ":")))
    return 0 if result["pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
