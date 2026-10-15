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

Source audit risks for the next implementation pass: Lapce v0.4.6's
`lapce-proxy/src/buffer.rs::save` truncated the path without comparing the
on-disk contents to the opened version, while `lapce-app/src/doc.rs` ignores
external changes when the document is dirty. The draft patch now fingerprints
the opened bytes, refuses conflicting saves and pre-existing backups, and
writes through a temporary file; save failures now open a visible alert.
Focused Windows tests and GUI behavior are still pending. Per-file replace
exists, but a reviewable workspace-wide replacement was not established from
the inspected source. Keep that capability out of claims until implemented.

Baseline checks completed on 2026-10-15: CodeStrike desktop inspection,
Lapce/Zed/Helix source/licensing/platform review, pinned submodule/approved-logo
verification, patch application, `cargo fmt --check`, and root-source diff
inspection. The first hosted Windows run failed on CRLF patch application;
the workflow now sets `core.autocrlf=false` before checkout. The second hosted
run [compiled the patched Windows binary and passed `--version`/`--help`](https://github.com/Gerbzz/CodeStrike/actions/runs/38712789811):
`CodeStrike 0.4.6+Debug.b012cef`, in 5m48s. The expanded startup/settings
patch also [compiled and passed CLI smoke tests](https://github.com/Gerbzz/CodeStrike/actions/runs/38714317402)
in 7m51s. Its first GUI probe watched the short-lived launcher rather than
the editor process, so that step failed without establishing a GUI result.
The probe now invokes `--wait` and must be rerun. No GUI feature acceptance
or release has been recorded yet. The following
[save patch run](https://github.com/Gerbzz/CodeStrike/actions/runs/38715669757)
stopped at one Rust callback type-inference error before its tests; the draft
now supplies the explicit RPC result type. The next
[run](https://github.com/Gerbzz/CodeStrike/actions/runs/38716861515)
compiled the current source and passed two of three save tests. The backup
test used the wrong filename (`main.rsbak` instead of Lapce's actual
`main.rs.bak`), so the fixture was corrected. That run skipped the GUI probe
after the test failure; the workflow now probes GUI before the tests and runs
the tests even if the probe fails. Do not advertise pending rows.
