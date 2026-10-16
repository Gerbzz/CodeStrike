# CodeStrike Lapce candidate: Windows GUI captures

These are unedited JPEG frames decoded from the `CODESTRIKE_SCREENSHOT_*_BASE64`
and `CODESTRIKE_ACCEPTANCE_SCREENSHOT_*_BASE64` log markers in the hosted
Windows runs identified below. The images show the **new pinned-Lapce candidate**, not the original CodeStrike
launcher or a release package. They include the runner desktop and terminal;
the window is not maximized. No image edits, crops, or composites were made.

The first three came from [run 38720659614](https://github.com/Gerbzz/CodeStrike/actions/runs/38720659614),
job `116374116215`, which compiled draft commit
`73b8346d261d450a4021fcfc6e0af08cc8285893` on `windows-latest`.

| Capture | What the frame verifies | SHA-256 |
| --- | --- | --- |
| [Startup](startup.jpg) | Approved CodeStrike mark, name, Open folder and Open file actions in a running window. | `1d8c909839c4029c2259ce3301f1e0636ad685e811228ce04e14c204e697621d` |
| [Folder](folder.jpg) | Explorer lists a synthetic folder containing `main.rs` and `notes.txt`. | `97e2bb662e80530a894516585fe987361219b2ccb0390d57e5bcef02dcfbb95b` |
| [Editor](file.jpg) | `main.rs` is a tab and displays the keyboard-inserted `codestrike_ci_saved` marker. The run separately asserted Ctrl+S wrote the marker to disk. | `2fde71ddca1cfd2d6ccbe373677fe5c35155d20e2fb4f003aff92d2f35f39aa9` |

The next four came from [run 38724671470](https://github.com/Gerbzz/CodeStrike/actions/runs/38724671470),
job `116387451149`, which compiled draft commit
`75843fa845fbef5de9f0af84f93be0a6ffdfd541` on `windows-latest`.

| Capture | What the frame verifies | SHA-256 |
| --- | --- | --- |
| [Three tabs](tabs.jpg) | `one.rs`, `two.rs`, and `three.rs` are open; the run asserted one distinct saved marker per file. | `11b1c81bc18acb43e58c7dd61c95726017a40f3069294fe92f298ea66ce4d91f` |
| [Reopened session](reopened.jpg) | The same three tabs returned after graceful close; the run asserted a second distinct saved marker per file. | `55d96ce6c47bdd772886a0f317c493faf63381635db011c38f297a62a7f4573a` |
| [Workspace search](workspace-search.jpg) | The search panel visibly lists three `codestrike_search_needle` matches across `main.rs` and `other.rs`. This frame alone does not test navigation or replacement. | `d1bd6a4c6b19992ceb377d31cbaa76e6cf7fe352cf5526f9cd5fddb947705b4c` |
| [GUI conflict](gui-conflict.jpg) | The alert reports an external disk change while the unsaved local edit remains visible. The run asserted the external file bytes were preserved. | `ba2c8599bcfa5ac1481f83819a1e5b0c64dde36e3e60b0645f81cd27c1b0f889` |

The final three came from [run 38735350052](https://github.com/Gerbzz/CodeStrike/actions/runs/38735350052),
job `116423124732`, which compiled draft commit
`fa6e9b8e0b06a2b3c1a9f5ff1f6b01ededc490ba` on `windows-latest`.

| Capture | What the frame verifies | SHA-256 |
| --- | --- | --- |
| [Search result opened](search-result.jpg) | Clicking the `other.rs` hit opened that file and showed its match; the run then asserted a keyboard edit saved to `other.rs`. Exact caret range was not asserted. | `972784c134631cbadfa89d18ac57b21f2ac8c23fe84c4555d5093b6fd34098f8` |
| [Replace field ready](replace-ready.jpg) | Tab from Find expanded Replace and entered `codestrike_replaced` into the replacement input. | `181c8e599ff354952dd9010f2e24e7096ad183dee6c67219dc0bc0fbaa8b7fef` |
| [Per-file replace applied](replace-applied.jpg) | The find bar shows no remaining hits in `main.rs` after Replace All; the run asserted exactly two replacements on disk in `main.rs`, while `other.rs` retained its match. | `10894b6d029e5f22aee0ed5f8f48220a47b3a9af59be531178373dc523166506` |

The next four came from [run 38738590545](https://github.com/Gerbzz/CodeStrike/actions/runs/38738590545),
job `116434127701`, which compiled draft commit
`b343191ac9d85bb95efb178299486899f3d23dcb` on `windows-latest`.

| Capture | What the frame verifies | SHA-256 |
| --- | --- | --- |
| [Exact search result opened](exact-search-result.jpg) | The clicked `other.rs` hit is open. The run separately typed `nav_`, saved, and asserted the entire file was exactly `let café = nav_codestrike_search_needle;` followed by LF. This tests the hit's UTF-8 byte column; the frame was taken before the edit. | `de254cad200c235a75c15c75f5ed5a41fcd1f0591639d41b21ae6a20cd672312` |
| [UTF-8 LF reopened](utf8-lf-reopened.jpg) | Supported Unicode/LF fixture open after a close and reopen. The run separately compared exact file bytes after two GUI edit/save rounds. | `581bccebd425440d242f840e2a703c6e88da2beaf0ae5d38c59a28b6e8530aff` |
| [UTF-8 BOM CRLF reopened](bom-crlf-reopened.jpg) | BOM/CRLF fixture open after a close and reopen. The run separately compared exact file bytes, including the BOM and CRLF, after two GUI edit/save rounds. | `0f9e39742bc0585202e012537085f0691593c10baa2b23f02c9cf6029e82a022` |
| [Unsupported encoding read-only](unsupported-read-only.jpg) | The UTF-16 fixture displays the read-only explanation. The run separately asserted UTF-16, Latin-1, and NUL-containing fixtures retained their exact original bytes after attempted GUI edits and saves. | `b497150efc7acdaa9c75aeb5d459f1cbea2610ca16fc746fe6b9f34abdfe6ca8` |

All fixtures were created under the hosted runner's temporary directory by
[`scripts/probe-windows-editor.ps1`](../../../scripts/probe-windows-editor.ps1)
or [`scripts/probe-editor-acceptance.ps1`](../../../scripts/probe-editor-acceptance.ps1).
The captures above do not establish workspace-wide replacement, selected
match-range highlighting, local language tooling, or clean-machine installation.

The [workspace replacement focus failure](workspace-replace-focus-failure.jpg)
is an unedited `workspace_replace_ready` capture from
[run 38752808636](https://github.com/Gerbzz/CodeStrike/actions/runs/38752808636),
job `116483308591`, commit `4ded974155c1e90f52b3faa7d6749eadb8d8f3f0`.
SHA-256: `7ee212042b2aa3b53facd67347fb13d22a68137e4ba57de0bcdbeb33e51abcb0`.
The replacement string is visibly appended to the workspace search query,
while the replacement input is empty. The same run passed eight save and four
replacement engine tests, then failed the GUI byte assertion at Apply. This
capture retains the failure that motivated the control and focus repair.

The following unedited frames came from the passing
[run 38757901744](https://github.com/Gerbzz/CodeStrike/actions/runs/38757901744),
job `116501116239`, which compiled draft commit
`9a77ed67b69f0c8b0d483d9980a80379f7a62edb` on `windows-latest`.
The GUI probe separately compared full fixture bytes at every stage and
emitted `CODESTRIKE_ACCEPTANCE_WORKSPACE_REPLACE=preview-conflict-apply-undo-passed`.

| Capture | What the frame shows | SHA-256 |
| --- | --- | --- |
| [Replacement input ready](workspace-replace-ready.jpg) | Search query unchanged and replacement text in the focused replacement field. | `dd4f48b848c3190d4253341294711f8e9495169e916cac4c6381d165891e3c46` |
| [Two-file preview](workspace-replace-preview.jpg) | Two matches listed with paths, positions, context, and replacement text before writes. | `319d50415340a9086517235a13441fdc2c2bfd7c6e6feb8991a63c09ddb5929e` |
| [Apply conflict](workspace-replace-apply-conflict.jpg) | Changed-since-preview refusal after an external edit to `two.rs`; the probe asserted no planned file was overwritten. | `3bcc425a93da23eacbc42eba84e73df87c834163a3f95096b3ac40166298e1ca` |
| [Applied](workspace-replace-applied.jpg) | Status reports two matches applied across two files; the probe compared exact bytes, including BOM and CRLF. | `d5a20b68b8f20648aca3b96f7bd3a5f9931441f2568ba39b94ed9ac2f37b630e` |
| [Undo conflict](workspace-replace-undo-conflict.jpg) | Undo refuses a newer edit; the probe asserted applied and newer bytes were retained. | `1ae571667cea5439dd8323fea567cdc5a36f38f1e937b06f2916447cd62b40cc` |
| [Checked undo](workspace-replace-undone.jpg) | Status reports two restored files; the probe asserted exact original bytes. Recovery backups remain visible. | `978f9b5c27ca2ce52ad21d4ecb0c40b49402ae2723686d975707b1ad36f103cb` |
