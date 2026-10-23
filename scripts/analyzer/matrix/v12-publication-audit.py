"""Validate every versioned diagnostic and range in the hosted LSP matrix."""

import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("matrix", HERE / "v7-final-state-matrix.py")
matrix = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(matrix)


def expected_texts(scenario):
    invalid = matrix.probe.INVALID
    valid = matrix.probe.VALID
    if scenario == "multi_file":
        invalid = "mod other;\n" + invalid
        valid = "mod other;\n" + valid
    if scenario == "new_file_reload":
        prefix = "".join(f"mod helper_{index};\n" for index in range(24))
        invalid = prefix + invalid
        valid = prefix + valid
    texts = {"main.rs": {1: invalid}}
    if scenario in ("final_invalid_priming", "enable_build", "enable_proc", "workspace_reload"):
        texts["main.rs"][2] = valid
        texts["main.rs"][3] = matrix.DISTINCT_INVALID + "\n// final invalid v3\n"
    elif scenario == "final_valid_priming":
        texts["main.rs"][2] = valid + "\n// final valid v2\n"
    elif scenario in ("alternating_final_valid", "alternating_final_invalid"):
        last = 6 if scenario == "alternating_final_valid" else 5
        for version in range(2, last + 1):
            text = valid if version % 2 == 0 else matrix.DISTINCT_INVALID
            texts["main.rs"][version] = text + f"\n// alternating v{version}\n"
    elif scenario == "multi_file":
        texts["main.rs"][2] = valid + "\n// final main v2\n"
        texts["other.rs"] = {
            1: 'pub fn other() { let value: i32 = "wrong"; }\n',
            2: "pub fn other() { let value: i32 = 7; }\n",
            3: "pub fn other() { let value: i32 = true; }\n// final other v3\n",
        }
    elif scenario == "new_file_reload":
        texts["main.rs"][2] = "mod new;\n" + valid + "\n// final with new module\n"
        texts["new.rs"] = {1: "pub fn new_fn() { let value: i32 = true; }\n"}
    return texts


def expected_error(text):
    if '"wrong"' in text:
        return '"wrong"', "found &'static str"
    if "= true;" in text:
        return "true", "found bool"
    return None


def check_detail(detail, text):
    expected = expected_error(text)
    if expected is None:
        return "diagnostic on valid document"
    token, message = expected
    if detail.get("code") != "E0308" or detail.get("source") != "rust-analyzer":
        return "unexpected code or source"
    if message not in str(detail.get("message", "")):
        return "wrong mismatch message"
    region = detail.get("range", {})
    start, end = region.get("start", {}), region.get("end", {})
    line, stop_line = start.get("line"), end.get("line")
    begin, stop = start.get("character"), end.get("character")
    lines = text.splitlines()
    if (not all(isinstance(value, int) for value in (line, stop_line, begin, stop))
            or line != stop_line or line < 0 or line >= len(lines)
            or begin < 0 or stop <= begin or stop > len(lines[line])):
        return "invalid diagnostic range"
    if lines[line][begin:stop] != token:
        return "range does not select mismatched expression"
    return None


def audit(scenario, log_directory, expected_binary_sha, expected_patch_sha):
    log = log_directory / f"matrix-{scenario}.log"
    result = json.loads(next(line.split("=", 1)[1] for line in log.read_text(encoding="utf-8").splitlines()
                             if line.startswith("V3_FINAL_STATE_MATRIX=")))
    texts = expected_texts(scenario)
    records = result["diagnostics_all"]
    problems = []
    if not result["pass"] or result["diagnostics_total"] != len(records):
        problems.append("matrix failed or publications were truncated")
    if result["binary_sha256"] != expected_binary_sha:
        problems.append("unexpected binary")
    if result["patch_sha256"] != expected_patch_sha:
        problems.append("unexpected patch")
    by_file = {}
    for item in records:
        name = item["uri"].rsplit("/", 1)[-1].casefold()
        version = item["version"]
        by_file.setdefault(name, []).append(item)
        text = texts.get(name, {}).get(version)
        if text is None:
            problems.append(f"{name}: unknown document version {version}")
            continue
        details = item["details"]
        if item["codes"] != [detail.get("code") for detail in details]:
            problems.append(f"{name}: summary differs from full details")
        if len(details) > 1:
            problems.append(f"{name}: more than one native error")
        for detail in details:
            problem = check_detail(detail, text)
            if problem:
                problems.append(f"{name} v{version}: {problem}")
    for name, items in by_file.items():
        versions = [item["version"] for item in items if item["version"] is not None]
        if versions != sorted(versions):
            problems.append(f"{name}: outbound version regressed")
        if len(items) > 20:
            problems.append(f"{name}: publication count exceeded 20")
    return {"scenario": scenario, "pass": not problems, "counts":
            {name: len(items) for name, items in by_file.items()}, "problems": problems}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("log_directory", type=Path)
    args = parser.parse_args()
    binary_sha = hashlib.sha256(args.binary.read_bytes()).hexdigest().upper()
    patch_sha = hashlib.sha256(args.patch.read_bytes()).hexdigest().upper()
    reports = [audit(scenario, args.log_directory, binary_sha, patch_sha)
               for scenario in matrix.SCENARIOS]
    for report in reports:
        print(json.dumps(report, separators=(",", ":")))
    raise SystemExit(0 if all(report["pass"] for report in reports) else 2)
