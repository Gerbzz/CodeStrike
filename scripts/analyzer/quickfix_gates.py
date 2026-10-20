"""Separate genuine rustc and synthetic cross-file quick-fix cache gates."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from lsp_fixture import BOOL, Client, fixture, options

HERE = Path(__file__).resolve().parent
GENUINE = "mod model;\ntrait View { type Out; }\nimpl View for model::Holder<'_> { type Out = &str; }\nfn main() {}\n"
MODEL = "pub struct Holder<'a>(pub &'a str);\n"
SYNTHETIC_LIB = "pub fn helper() -> i32 { 1 }\n"


def actions(client, uri, line):
    return client.request("textDocument/codeAction", {
        "textDocument": {"uri": uri},
        "range": {"start": {"line": line, "character": 0},
                  "end": {"line": line, "character": 65}},
        "context": {"diagnostics": []},
    }, 15) or []


def edits(item):
    return item.get("edit", {}).get("changes") or {}


def has_rustc(client, uri, text):
    return any(d.get("source") == "rustc" and text in d.get("message", "")
               for report in client.reports(uri, 1) for d in report["diagnostics"])


def compiler_lifetime_edits(root, source, base):
    """Get the expected same-file WorkspaceEdit from this fixture's real rustc JSON."""
    env = os.environ.copy()
    env.update({"CARGO_NET_OFFLINE": "true", "CARGO_TARGET_DIR": str(base / "compiler-target")})
    run = subprocess.run(["cargo", "check", "--locked", "--offline", "--message-format=json",
                          "--manifest-path", str(root / "Cargo.toml")], cwd=root, env=env,
                         capture_output=True, text=True, timeout=45)
    messages = [entry["message"] for line in run.stdout.splitlines()
                if (entry := json.loads(line)).get("reason") == "compiler-message"
                and entry.get("message", {}).get("message") == "missing lifetime in associated type"]
    if run.returncode == 0 or len(messages) != 1:
        raise AssertionError("fixture compiler did not produce one lifetime error")
    suggestions = [child for child in messages[0].get("children", [])
                   if child.get("level") == "help" and "add a lifetime" in child.get("message", "")]
    if len(suggestions) != 1:
        raise AssertionError("fixture compiler lifetime suggestion missing or ambiguous")
    edits = []
    for span in suggestions[0].get("spans", []):
        replacement = span.get("suggested_replacement")
        if replacement is None:
            continue
        target = (root / span["file_name"].replace("\\", "/")).resolve()
        if target != source.resolve():
            raise AssertionError("compiler suggestion targets another file")
        edits.append((target.as_uri().casefold(), span["line_start"] - 1, span["column_start"] - 1,
                      span["line_end"] - 1, span["column_end"] - 1, replacement))
    if len(edits) != 3 or len(set(edits)) != 3:
        raise AssertionError("fixture compiler did not suggest three distinct edits")
    return tuple(sorted(edits))


def action_edit_tuples(item):
    return tuple(sorted((uri.casefold(), edit["range"]["start"]["line"],
                         edit["range"]["start"]["character"],
                         edit["range"]["end"]["line"],
                         edit["range"]["end"]["character"], edit["newText"])
                        for uri, changes in edits(item).items() for edit in changes))


def run_genuine(binary, base):
    root, source, _ = fixture(base, GENUINE)
    model = root / "src/model.rs"
    model.write_bytes(MODEL.encode())
    uri = source.as_uri()
    expected_edits = compiler_lifetime_edits(root, source, base)
    client = Client(binary, root)
    result = {"case": "genuine-rustc-three-edit-same-file", "compiler_output": "actual cargo check"}
    try:
        client.initialize(options(check_on_save=True), [(source, GENUINE), (model, MODEL)])
        client.notify("textDocument/didSave", {"textDocument": {"uri": uri}})
        client.wait(lambda: has_rustc(client, uri, "missing lifetime in associated type"),
                    45, "real rustc associated-type diagnostic")
        before = [item for item in actions(client, uri, 2) if "add a lifetime" in item.get("title", "")]
        result["before_edit_counts"] = [sum(len(value) for value in edits(item).values())
                                        for item in before]
        result["compiler_edit_count"] = len(expected_edits)
        result["exact_compiler_action_count"] = sum(
            {target.casefold() for target in edits(item)} == {uri.casefold()}
            and action_edit_tuples(item) == expected_edits
            for item in before)
        dirty = GENUINE.replace("type Out = &str", "type Out = String")
        client.notify("textDocument/didChange", {"textDocument": {"uri": uri, "version": 2},
                                                   "contentChanges": [{"text": dirty}]})
        result["server_dirty"] = client.request("rust-analyzer/viewFileText", {"uri": uri}) == dirty
        result["disk_unchanged"] = source.read_bytes() == GENUINE.encode()
        after = [item for item in actions(client, uri, 2) if "add a lifetime" in item.get("title", "")]
        client.hold(15)
        after_hold = [item for item in actions(client, uri, 2)
                      if "add a lifetime" in item.get("title", "")]
        result["after_count"], result["after_hold_count"] = len(after), len(after_hold)
        result["pass"] = bool(result["exact_compiler_action_count"] >= 1 and result["server_dirty"]
                              and result["disk_unchanged"] and not after and not after_hold)
    finally:
        result["shutdown"] = client.close()
    result["pass"] = result["pass"] and result["shutdown"]
    return result


def run_synthetic(binary, base):
    root, source, _ = fixture(base, BOOL)
    target = root / "src/lib.rs"
    target.write_bytes(SYNTHETIC_LIB.encode())
    uri, target_uri = source.as_uri(), target.as_uri()
    config = options(check_on_save=True)
    emitter = HERE / "emit-synthetic-two-file.py"
    config["check"] = {"overrideCommand": [sys.executable, str(emitter)],
                       "invocationStrategy": "once"}
    client = Client(binary, root)
    result = {"case": "synthetic-two-file-cache-lifecycle", "emitter_sha256":
              hashlib.sha256(emitter.read_bytes()).hexdigest().upper()}
    try:
        client.initialize(config, [(source, BOOL), (target, SYNTHETIC_LIB)])
        client.wait(lambda: has_rustc(client, uri, "synthetic two-file type mismatch"),
                    40, "synthetic Cargo JSON diagnostic admitted")
        before = [item for item in actions(client, uri, 1) if "apply paired fix" in item.get("title", "")]
        result["before_targets"] = [sorted(edits(item)) for item in before]
        dirty = SYNTHETIC_LIB + "// unsaved target change\n"
        client.notify("textDocument/didChange", {"textDocument": {"uri": target_uri, "version": 2},
                                                   "contentChanges": [{"text": dirty}]})
        result["server_dirty"] = client.request("rust-analyzer/viewFileText", {"uri": target_uri}) == dirty
        result["disk_unchanged"] = target.read_bytes() == SYNTHETIC_LIB.encode()
        after = [item for item in actions(client, uri, 1) if "apply paired fix" in item.get("title", "")]
        client.hold(15)
        after_hold = [item for item in actions(client, uri, 1)
                      if "apply paired fix" in item.get("title", "")]
        result["after_count"], result["after_hold_count"] = len(after), len(after_hold)
        result["pass"] = bool(any(uri.casefold() in (x.casefold() for x in targets)
                                  and target_uri.casefold() in (x.casefold() for x in targets)
                                  for targets in result["before_targets"])
                              and result["server_dirty"] and result["disk_unchanged"]
                              and not after and not after_hold)
    finally:
        result["shutdown"] = client.close()
    result["pass"] = result["pass"] and result["shutdown"]
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("case", choices=("genuine", "synthetic"))
    parser.add_argument("binary", type=Path)
    parser.add_argument("work", type=Path)
    args = parser.parse_args()
    args.work.mkdir(parents=True, exist_ok=False)
    binary = args.binary.resolve()
    result = {"binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest().upper()}
    try:
        result.update(run_genuine(binary, args.work.resolve()) if args.case == "genuine"
                      else run_synthetic(binary, args.work.resolve()))
    except Exception as exc:
        result.update({"case": args.case, "pass": False, "error": str(exc)[:250]})
    print("CODESTRIKE_ANALYZER_QUICKFIX=" + json.dumps(result, separators=(",", ":")), flush=True)
    return 0 if result["pass"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
