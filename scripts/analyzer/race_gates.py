"""Acknowledged cancellation and delayed-save gates using test-only source hooks."""

import argparse
import hashlib
import json
from pathlib import Path

from lsp_fixture import BOOL, INVALID, VALID, Client, fixture, options

OTHER = 'pub fn other() { let value: i32 = "wrong"; }\n'


def flycheck_ends(client):
    return sum(item["kind"] == "end" and "flycheck" in item["token"]
               for item in client.progress)


def has_error(client, uri, version, source=None, needle=None):
    return any(item.get("code") == "E0308"
               and (source is None or item.get("source") == source)
               and (needle is None or needle in str(item.get("message", "")))
               for report in client.reports(uri, version)
               for item in report["diagnostics"])


def latest(client, uri):
    reports = client.reports(uri)
    return reports[-1] if reports else None


def mismatch(text):
    if '"wrong"' in text:
        return '"wrong"', "str"
    if "= true;" in text:
        return "true", "bool"
    return None


def selects_token(detail, text, token):
    region = detail.get("range", {})
    start, end = region.get("start", {}), region.get("end", {})
    line, stop_line = start.get("line"), end.get("line")
    begin, stop = start.get("character"), end.get("character")
    lines = text.splitlines()
    return (all(isinstance(value, int) for value in (line, stop_line, begin, stop))
            and line == stop_line and 0 <= line < len(lines)
            and 0 <= begin < stop <= len(lines[line])
            and lines[line][begin:stop] == token)


def native_latest_error(report, version, text):
    expected = mismatch(text)
    if not report or report["version"] != version or expected is None:
        return False
    details = report["diagnostics"]
    message = "found bool" if expected[1] == "bool" else "found &'static str"
    return (len(details) == 1 and details[0].get("code") == "E0308"
            and details[0].get("source") == "rust-analyzer"
            and message in str(details[0].get("message", ""))
            and selects_token(details[0], text, expected[0]))


def latest_expected_error(report, version, text):
    expected = mismatch(text)
    if not report or report["version"] != version or expected is None:
        return False
    return any(detail.get("code") == "E0308"
               and detail.get("source") in ("rust-analyzer", "rustc")
               and expected[1] in str(detail.get("message", ""))
               and selects_token(detail, text, expected[0])
               for detail in report["diagnostics"])


def audit_publications(client, documents, native_only=False):
    """Check every retained publication without requiring intermediate versions to publish."""
    expected = {uri.casefold(): versions for uri, versions in documents.items()}
    last_version = {}
    counts = {uri: 0 for uri in expected}
    problems = []
    if client.diagnostics_overflow:
        problems.append("diagnostic history exceeded 128 publications")
    for index, report in enumerate(client.diagnostics):
        uri = report["uri"].casefold()
        versions = expected.get(uri)
        if versions is None:
            problems.append(f"publication {index}: unexpected URI")
            continue
        counts[uri] += 1
        version = report["version"]
        if version not in versions:
            problems.append(f"publication {index}: unexpected version {version}")
            continue
        if version < last_version.get(uri, version):
            problems.append(f"publication {index}: version regressed")
        last_version[uri] = version
        text = versions[version]
        expected_error = mismatch(text)
        details = report["diagnostics"]
        if native_only and len(details) > 1:
            problems.append(f"publication {index}: multiple native diagnostics")
        primary_seen = False
        related_seen = False
        for detail in details:
            if detail.get("code") != "E0308":
                if native_only or detail.get("severity") == 1:
                    problems.append(f"publication {index}: unexpected diagnostic code")
                continue
            if expected_error is None:
                problems.append(f"publication {index}: stale E0308 on valid text")
                continue
            message = str(detail.get("message", ""))
            if expected_error[1] in message:
                primary_seen = True
                if detail.get("source") not in ("rust-analyzer", "rustc") or not selects_token(
                        detail, text, expected_error[0]):
                    problems.append(f"publication {index}: wrong E0308 source or range")
            elif (not native_only and detail.get("source") == "rustc"
                  and "expected due to this" in message):
                related_seen = True
                if not selects_token(detail, text, "i32"):
                    problems.append(f"publication {index}: wrong rustc related range")
            else:
                problems.append(f"publication {index}: E0308 from wrong document state")
            if native_only and (detail.get("source") != "rust-analyzer"
                                or not selects_token(detail, text, expected_error[0])):
                problems.append(f"publication {index}: wrong native source or range")
        if related_seen and not primary_seen:
            problems.append(f"publication {index}: rustc related item without matching primary")
    if not all(counts.values()):
        problems.append("opened fixture file has no diagnostic publication")
    return {"counts": counts, "problems": problems}


def settled_snapshot(client, exact_texts, documents, native_only=False):
    """Drain publications after the last file-text request, then inspect final state."""
    exact = {label: client.exact(path, text) for label, path, text in exact_texts}
    client.hold(3)
    reports = {uri: latest(client, uri) for uri in documents}
    audit = audit_publications(client, documents, native_only=native_only)
    return exact, reports, audit


def run_cancel(binary, base, kind, count):
    initial, valid, invalid = ("mod other;\n" + text for text in (INVALID, VALID, BOOL))
    root, source, other = fixture(base, initial, OTHER)
    gate, temp = base / "ack", base / "temp"
    gate.mkdir()
    temp.mkdir()
    client = Client(binary, root, {"TEMP": str(temp), "TMP": str(temp),
                                   "RA_TEST_CANCEL_ACK_DIR": str(gate),
                                   "RA_TEST_CANCEL_MODE": kind,
                                   "RA_TEST_CANCEL_COUNT": str(count)})
    result = {"scenario": kind, "forced_count": count}
    uri, other_uri = source.as_uri(), other.as_uri()
    try:
        client.initialize(options(), [(source, initial), (other, OTHER)])
        client.wait(lambda: has_error(client, uri, 1), 30, "initial v1 mismatch")
        client.edit(source, 2, valid)
        client.wait(lambda: any(not report["diagnostics"] for report in client.reports(uri, 2)),
                    30, "valid v2 clear")
        client.edit(source, 3, invalid)
        client.wait(lambda: (gate / f"attempt-{kind}-{count}").exists(),
                    45, "all forced cancellations acknowledged")
        client.hold(15)
        expected_attempts = [gate / f"attempt-{kind}-{index}" for index in range(1, count + 2)]
        exact, reports, audit = settled_snapshot(client, [
            ("main_v3", source, invalid), ("other_v1", other, OTHER),
        ], {
            uri: {1: initial, 2: valid, 3: invalid},
            other_uri: {1: OTHER},
        }, native_only=True)
        report, other_report = reports[uri], reports[other_uri]
        result.update({
            "attempts": sorted(path.name for path in gate.glob("attempt-*")),
            "slices": sorted(path.name for path in gate.glob("slice-*")),
            "exact_main_v3": exact["main_v3"],
            "exact_other_v1": exact["other_v1"],
            "last_main_version": report["version"] if report else None,
            "last_main_codes": [d.get("code") for d in report["diagnostics"]] if report else [],
            "last_other_version": other_report["version"] if other_report else None,
            "last_other_codes": [d.get("code") for d in other_report["diagnostics"]] if other_report else [],
            "publication_audit": audit,
        })
        result["pass"] = bool(
            all(path.exists() for path in expected_attempts)
            and f"slice-{kind}-0-1" in result["slices"]
            and f"slice-{kind}-1-2" in result["slices"]
            and result["exact_main_v3"] and result["exact_other_v1"]
            and native_latest_error(report, 3, invalid)
            and native_latest_error(other_report, 1, OTHER)
            and not audit["problems"])
    finally:
        result["shutdown"] = client.close()
    result["pass"] = result["pass"] and result["shutdown"]
    return result


def run_save_order(binary, base, reverse):
    root, source, _ = fixture(base)
    gate, temp = base / "old-worker-gate", base / "temp"
    gate.mkdir()
    temp.mkdir()
    client = Client(binary, root, {"TEMP": str(temp), "TMP": str(temp),
                                   "RA_DELAY_FIRST_SAVE_RESTART_DIR": str(gate)})
    result = {"scenario": "reverse-save" if reverse else "cancel-save"}
    uri = source.as_uri()
    try:
        client.initialize(options(check_on_save=True), [(source, INVALID)])
        client.wait(lambda: flycheck_ends(client) >= 1, 35, "initial flycheck end")
        source.write_bytes(INVALID.encode("utf-8"))
        client.notify("textDocument/didSave", {"textDocument": {"uri": uri}})
        client.wait(lambda: (gate / "ready").exists(), 25, "first save worker held")
        if reverse:
            final = BOOL + "\n// newer saved buffer\n"
            client.edit(source, 2, final)
            client.notify("textDocument/didSave", {"textDocument": {"uri": uri}})
            client.wait(lambda: has_error(client, uri, 2, "rustc", "found `bool`")
                        and flycheck_ends(client) >= 2, 50, "newer rustc bool result")
        else:
            final = INVALID
            client.notify("rust-analyzer/cancelFlycheck", None)
            client.wait(lambda: (gate / "cancel-processed").exists(),
                        25, "explicit Cancel acknowledged")
        ends_before = flycheck_ends(client)
        (gate / "release").write_text("release", encoding="utf-8")
        client.wait(lambda: (gate / "resumed").exists(), 25, "old save worker resumed")
        client.wait(lambda: (gate / "postrelease-rejected").exists()
                    or (gate / "postrelease-accepted").exists(), 25,
                    "old restart disposition acknowledged")
        client.hold(15)
        versions = {1: INVALID}
        if reverse:
            versions[2] = final
        exact, reports, audit = settled_snapshot(client, [("final", source, final)],
                                                 {uri: versions})
        report = reports[uri]
        result.update({"worker_resumed": (gate / "resumed").exists(),
                       "old_restart_rejected": (gate / "postrelease-rejected").exists(),
                       "old_restart_accepted": (gate / "postrelease-accepted").exists(),
                       "ends_before_release": ends_before,
                       "ends_after_release": flycheck_ends(client),
                       "exact_final": exact["final"],
                       "last_version": report["version"] if report else None,
                       "last_codes": [d.get("code") for d in report["diagnostics"]] if report else [],
                       "publication_audit": audit})
        result["pass"] = bool(result["worker_resumed"] and result["old_restart_rejected"]
                              and not result["old_restart_accepted"]
                              and result["ends_after_release"] == ends_before
                              and result["exact_final"]
                              and not audit["problems"]
                              and latest_expected_error(report, 2 if reverse else 1, final)
                              and (not reverse or (report and report["version"] == 2
                                                   and any(d.get("code") == "E0308"
                                                           and d.get("source") == "rustc"
                                                           and "found `bool`" in str(d.get("message", ""))
                                                           for d in report["diagnostics"]))))
    finally:
        (gate / "release").write_text("release", encoding="utf-8")
        result["shutdown"] = client.close()
    result["pass"] = result["pass"] and result["shutdown"]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", choices=("syntax", "semantic", "cancel-save", "reverse-save"))
    parser.add_argument("binary", type=Path)
    parser.add_argument("work", type=Path)
    parser.add_argument("--count", type=int, default=2)
    args = parser.parse_args()
    if not 1 <= args.count <= 8:
        parser.error("count must be between 1 and 8")
    binary = args.binary.resolve()
    args.work.mkdir(parents=True, exist_ok=False)
    result = {"binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest().upper()}
    try:
        if args.scenario in ("syntax", "semantic"):
            result.update(run_cancel(binary, args.work.resolve(), args.scenario, args.count))
        else:
            result.update(run_save_order(binary, args.work.resolve(), args.scenario == "reverse-save"))
    except Exception as exc:
        result.update({"scenario": args.scenario, "pass": False, "error": str(exc)[:250]})
    print("CODESTRIKE_ANALYZER_RACE=" + json.dumps(result, separators=(",", ":")), flush=True)
    return 0 if result["pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
