# CodeStrike editor acceptance matrix

Every full row below remains **pending** for the Lapce-based CodeStrike candidate;
the narrower passed probes are recorded after the table.
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
Six focused Windows save tests now pass. The tested GUI conflict and encoding
paths are recorded below; recovery and broader save behavior remain pending.
Per-file replace and a checked workspace replacement candidate now exist in
the draft patch. The proxy engine has focused Windows tests; the complete
native GUI preview/apply/undo path is still under verification. See
[workspace replacement design](WORKSPACE_REPLACE.md) for bounds and recovery
limits.

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
the tests even if the probe fails. The following
[run](https://github.com/Gerbzz/CodeStrike/actions/runs/38718055396)
compiled and passed branded CLI smoke plus all three save tests. The GUI
process exposed a window handle but an empty native title, so the title-only
probe failed before capturing pixels. The probe now brings that window forward
and captures the screen for direct visual inspection. The
[next hosted run](https://github.com/Gerbzz/CodeStrike/actions/runs/38719598511)
passed compilation, CLI smoke, both GUI captures, and all three save tests.
The startup capture shows the approved logo, CodeStrike name, and Open folder/
Open file buttons. The folder capture shows the real fixture tree with
`main.rs` and `notes.txt`; it does not yet prove file editing or reopening.
The [following run](https://github.com/Gerbzz/CodeStrike/actions/runs/38720659614)
also passed a real Windows GUI edit/save probe. It opened `main.rs` as a tab,
sent a keyboard edit and Ctrl+S, captured the edited content in the window,
and asserted the marker appeared on disk. All three proxy save tests passed
again. This establishes one normal UTF-8 file edit/save path, not the full
file/session, encoding, search, or language-tooling rows. Do not advertise
pending rows.

The [first three-tab run](https://github.com/Gerbzz/CodeStrike/actions/runs/38722983849)
compiled and passed the proxy tests but neither GUI probe observed a window
within its 20–30 second limit. It established no new GUI result. The
[bounded rerun](https://github.com/Gerbzz/CodeStrike/actions/runs/38724671470)
allowed 120 seconds for GUI startup and passed: three distinct file edits and
saves, graceful close, restored tabs, and three further distinct edits/saves;
workspace search visibly returned three matches in two fixture files; a dirty
GUI buffer refused to overwrite an external file change and displayed an
alert while the external bytes remained intact. The unedited
[screenshots and hashes](evidence/README.md) provide visual provenance.
The [calibrated navigation run](https://github.com/Gerbzz/CodeStrike/actions/runs/38729935295)
opened the clicked workspace search result in `other.rs`, then edited and
saved that file; the assertion passed. The same run's Replace All probe clicked
left of the collapsed replace toggle, so it established no replacement result.
The [next run](https://github.com/Gerbzz/CodeStrike/actions/runs/38731656949)
opened the replacement row, but the probe clicked below its input and icon;
the captured frame shows the replacement marker in the file buffer instead.
The [visible-center run](https://github.com/Gerbzz/CodeStrike/actions/runs/38733101720)
also failed the replacement assertion because the toggle click did not expand
the row consistently; the screenshot shows replacement text in Find. The draft
then made Tab from Find open and focus Replace. The resulting
[Windows run 38735350052](https://github.com/Gerbzz/CodeStrike/actions/runs/38735350052)
passed compilation, CLI smoke, all three proxy save tests, three-tab reopen,
search-hit navigation, per-file Replace All, and GUI external-change conflict.
The search-hit check clicked the `other.rs` result and saved a marker in
`other.rs`; the replacement check used Tab to focus Replace, clicked Replace
All, and asserted that exactly two occurrences changed in `main.rs` while
`other.rs` retained its original match. The unedited
[search and replacement captures](evidence/README.md) show the UI states.
The [next Windows run 38738590545](https://github.com/Gerbzz/CodeStrike/actions/runs/38738590545)
passed all configured steps at draft commit `b343191`. Search navigation now
passes a stricter check: clicking a hit in `other.rs`, whose line has a
multibyte `é` before the match, then typing `nav_` and saving produced exactly
`let café = nav_codestrike_search_needle;` plus LF. The patch uses the
proxy-provided UTF-8 byte column rather than the line alone. This verifies
the edit caret for that hit, not match selection/highlighting or every search
shape. The run again passed three-tab reopen, per-file Replace All, and GUI
external-change conflict checks.

The same run passed six proxy save tests and GUI encoding checks. A UTF-8
Unicode/LF file and a UTF-8 BOM/CRLF file were each edited, saved, closed,
reopened, edited, and saved again; exact byte comparisons after each round
confirmed the original BOM and newline conventions. Invalid UTF-8, UTF-16,
and NUL-containing fixtures were made read-only by the proxy, and attempted
GUI edits/saves left their original bytes unchanged. See the
[unedited captures and hashes](evidence/README.md). This does not verify
other encodings, mixed newlines, every edit operation, or a recovery path.

The runner reported a `rust-analyzer` command on PATH but no installed
rustup `rust-analyzer` component. Local `rustup which rust-analyzer` also
reports no component. See [language tooling assessment](LOCAL_LANGUAGE_TOOLS.md).
The full search/replace row remains pending for selected match-range
highlighting, a GUI regex case, and broader workspace shapes. Split tabs,
local diagnostics/completion, full encoding coverage, and clean-machine
installation also remain unverified.

The workspace replacement draft adds a bounded preview, per-file checked
application, and checked undo. [Run 38755566964](https://github.com/Gerbzz/CodeStrike/actions/runs/38755566964)
compiled it and passed eight save tests and four replacement engine tests,
including regex captures, Unicode word behavior, BOM retention, and conflicts
before Apply and Undo. Its GUI capture shows the replacement text in the
replacement input with the search query unchanged. The GUI step did not reach
Apply: its click coordinates landed on the input because the logged capture
was resized relative to the native window. The earlier
[run 38752808636](https://github.com/Gerbzz/CodeStrike/actions/runs/38752808636)
captures the separate input-focus failure; the [unedited frame](evidence/workspace-replace-focus-failure.jpg)
is retained. No full GUI replacement pass is claimed from those runs.

[Run 38757901744](https://github.com/Gerbzz/CodeStrike/actions/runs/38757901744),
job `116501116239`, compiled draft commit `9a77ed67b69f0c8b0d483d9980a80379f7a62edb`
and passed every configured step. Eight save tests and four replacement engine
tests passed. In the native GUI, the replacement field received the intended
text while the search query stayed unchanged; Preview listed two files and
changed neither. An external edit after Preview blocked Apply without changing
either file. A fresh Preview then applied exactly two replacements across a
UTF-8 BOM/CRLF file and a UTF-8 LF file. Ignored, read-only, and invalid UTF-8
fixtures retained their original bytes. Checked Undo refused a newer edit;
after restoring the expected applied bytes, it restored both original files
exactly. The log marker is
`CODESTRIKE_ACCEPTANCE_WORKSPACE_REPLACE=preview-conflict-apply-undo-passed`.
See the [unedited GUI frames and hashes](evidence/README.md). This single
scenario does not prove crash recovery, cross-session Undo, multi-file
atomicity, or concurrent pathname swaps.
