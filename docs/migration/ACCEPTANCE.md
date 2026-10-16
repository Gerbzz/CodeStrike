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

## Clean external reload and guarded save

Independent source review found that an accepted clean-file reload updated the
editor text but left the proxy's disk fingerprint at the previous file version.
The proxy would then refuse a legitimate later save. The draft now sends an
acknowledgement only after the editor accepts a clean reload; the proxy accepts
it only when the revision and buffer bytes still match the file on disk. Twelve
focused save tests passed in [Windows run 38773380677](https://github.com/Gerbzz/CodeStrike/actions/runs/38773380677),
including stale-revision, unsaved-content, and newer-disk refusals. The dirty
GUI save-conflict check also passed.

The native clean-reload probe in that run remained red because the tab still
displayed its original text after an external write. The earlier test-only
[run 38770877977](https://github.com/Gerbzz/CodeStrike/actions/runs/38770877977)
showed the same limit; neither GUI failure alone exercised the accepted-reload
fingerprint path. A bounded trace in
[run 38777886375](https://github.com/Gerbzz/CodeStrike/actions/runs/38777886375)
showed the Windows modification event arriving and matching two watched paths.
Source inspection then found the handoff mismatch: CLI parsing canonicalizes
the open file to a `\\?\` path, while the watcher strips that prefix before
proxy buffer lookup. The draft resolves watch events back to the exact open
buffer key and includes Windows path tests. The full native GUI acceptance
result for that correction is recorded in
[run 38780232313](https://github.com/Gerbzz/CodeStrike/actions/runs/38780232313),
job `116578208785`, at code commit `42c8c15`. Every configured step passed:
12 proxy save tests, 4 replacement tests, startup, three-tab reopen, search,
workspace replacement, encoding, and dirty-file conflict. The clean-reload
GUI capture shows the external text in the open tab, then the probe appended
a local edit and asserted the exact combined UTF-8 bytes on disk. Its marker
is `CODESTRIKE_ACCEPTANCE_CLEAN_RELOAD=external-reload-and-save-passed`.
This verifies one Windows clean reload and later save, not every filesystem
watcher event or cross-platform path form. Full save/recovery acceptance above
remains pending for crash interruption and broader external-write cases.

## Opt-in local Rust diagnostics and completion

The [Windows language-tooling run 38953240177](https://github.com/Gerbzz/CodeStrike/actions/runs/38953240177),
job `117149602450`, passed at commit `046f0baff78e1015fa3759de2f51e89bdf5652ab`.
It built the pinned Apache-2.0 Rust Volt on the hosted runner and used an
explicitly installed rust-analyzer `1.99.0`. CodeStrike opened a disposable
Cargo workspace, sent `initialize` and `didOpen`, and received an `E0308`
diagnostic for an intentional type error. The bounded GUI screenshot shows
the open file and one error indicator. The server and Volt remain opt-in;
neither is bundled or enabled by default.

The advertised `get_completion` command was present in the pinned keymap and
Floem command enum but absent from Lapce's editor command handler. The draft
patch connects it to the existing completion request path. [Windows run
38957477121](https://github.com/Gerbzz/CodeStrike/actions/runs/38957477121),
job `117163870747`, passed at commit `e9a1e8e9348eb9fb29dd3883c9603f905e97890f`.
The GUI probe placed the caret within `use std::io::Read;`, invoked the
shortcut, observed `textDocument/completion` and a `Read` item from the local
server, and captured the visible nonempty menu. E0308 diagnostics passed again.
At that point, selecting/inserting an item, definition, code actions,
absent-server behavior, and clean-machine installation remained pending. See
[exact setup and provenance](LOCAL_LANGUAGE_TOOLS.md).

The follow-up [Windows run 38959531604](https://github.com/Gerbzz/CodeStrike/actions/runs/38959531604),
job `117170803799`, passed at commit `a081c5864171345cdc63c739aaad6584459b4cae`.
It selected `Read` from the visible menu for `use std::io::Re;`, saved, and
asserted the exact expanded Rust source on disk. In a second GUI session, a
unique nonexistent local server produced a visible error, the window stayed
open, and a completion/save attempt left the source hash unchanged. Both
screenshots are bounded app-window captures in the hosted log. This tests
one insertion and one unavailable-server configuration; definition, code
actions, broader failure recovery, and clean-machine installation remain
pending.
