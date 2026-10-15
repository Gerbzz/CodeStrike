# CodeStrike editor acceptance matrix

Every item below is **pending** for the Lapce-based CodeStrike candidate.
Upstream source inspection establishes implementation entry points, not a
passing CodeStrike product test. Record the exact commit, Windows version,
run method, fixture, result, and screenshot/log where useful for each run.

| Area | Test with real files | Pass condition |
| --- | --- | --- |
| Folder and explorer | Open a nested Rust project with ignored, hidden, and Unicode names; create, rename and delete a disposable file. | Correct tree and active file; filesystem operations affect only selected paths and errors are visible. |
| Tabs and session | Open at least three files, edit two, switch and split tabs, close/reopen app. | Distinct buffers and dirty markers; no edit loss or tab confusion; session restoration matches saved files. |
| Save and conflict | Edit CRLF/BOM fixture, save, then change same file externally before another save. | Preserves supported encoding/newlines; conflict is surfaced without overwriting the external edit; recovery path is tested. |
| Search/replace | Find across folder, open a hit, replace one and preview/confirm multi-file replace including regex and Unicode. | Hit opens at exact range; replacement set is reviewable; undo/rollback and excluded files behave as shown. |
| Language tools | Use an explicitly installed local rust-analyzer on a small Rust workspace, then disable/uninstall it. | Completion, definition, diagnostics and code actions work; absent server has a clear non-blocking message; no unrequested service download. |
| Core editing | Multiline selection, undo/redo, paste Unicode, line numbers, syntax colors, large file and binary refusal. | Editing remains responsive and no unsupported file is silently rewritten. |
| Startup/About and accessibility | Launch without a workspace, inspect About, keyboard navigate file/search/save dialogs at 100% and 200% scale. | Approved name/logo and attribution appear; working layout prioritizes code; primary tasks work by keyboard and visible focus. |
| Distribution | Install on clean Windows VM without dev dependencies; inspect package notices and disk use. | App launches and saves/reopens; bundled terms match exact contents; size and installed footprint recorded. |

Baseline checks completed on 2026-10-15: CodeStrike desktop inspection,
Lapce/Zed/Helix source/licensing/platform review, pinned submodule/approved-logo
verification, patch application, `cargo fmt --check`, and root-source diff
inspection. The first hosted Windows run failed on CRLF patch application;
the workflow now sets `core.autocrlf=false` before checkout. The second hosted
run [compiled the patched Windows binary and passed `--version`/`--help`](https://github.com/Gerbzz/CodeStrike/actions/runs/38712789811):
`CodeStrike 0.4.6+Debug.b012cef`, in 5m48s. This was the earlier patch;
the expanded startup/settings patch still needs CI. No GUI test, release,
or feature acceptance has been recorded yet. Do not advertise pending rows.
