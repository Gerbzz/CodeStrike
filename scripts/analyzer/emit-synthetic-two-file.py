"""Emit one valid Cargo JSON diagnostic with a two-file rustc suggestion."""

import json
import subprocess
from pathlib import Path


def span(file_name, line, start, end, replacement):
    return {
        "file_name": file_name, "byte_start": 0, "byte_end": 0,
        "line_start": 1 if file_name.endswith("lib.rs") else 2,
        "line_end": 1 if file_name.endswith("lib.rs") else 2,
        "column_start": start, "column_end": end,
        "is_primary": True, "text": [{"text": line,
                                      "highlight_start": start,
                                      "highlight_end": end}],
        "label": None, "suggested_replacement": replacement,
        "suggestion_applicability": "MachineApplicable", "expansion": None,
    }


root = Path.cwd()
metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--format-version=1", "--no-deps", "--offline"],
    text=True))
package = next(p for p in metadata["packages"] if Path(p["manifest_path"]).parent == root)
target = next(t for t in package["targets"] if "bin" in t["kind"])
a = (root / "src" / "main.rs").read_text(encoding="utf-8").splitlines()[1]
b = (root / "src" / "lib.rs").read_text(encoding="utf-8").splitlines()[0]
primary = span("src/main.rs", a, 30, 34, None)
primary["suggested_replacement"] = None
primary["suggestion_applicability"] = None
child = {
    "message": "apply paired fix", "code": None, "level": "help",
    "spans": [span("src/main.rs", a, 30, 34, "1"),
              span("src/lib.rs", b, 1, len(b) + 1,
                   "pub fn helper() -> i32 { 2 }")],
    "children": [], "rendered": None, "$message_type": "diagnostic",
}
message = {
    "message": "synthetic two-file type mismatch", "code": {"code": "E0308", "explanation": None},
    "level": "error", "spans": [primary], "children": [child],
    "rendered": "synthetic two-file type mismatch", "$message_type": "diagnostic",
}
print(json.dumps({"reason": "compiler-message", "package_id": package["id"],
                  "manifest_path": package["manifest_path"], "target": target,
                  "message": message}), flush=True)
print(json.dumps({"reason": "build-finished", "success": True}), flush=True)
