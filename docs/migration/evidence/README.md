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

All fixtures were created under the hosted runner's temporary directory by
[`scripts/probe-windows-editor.ps1`](../../../scripts/probe-windows-editor.ps1)
or [`scripts/probe-editor-acceptance.ps1`](../../../scripts/probe-editor-acceptance.ps1).
The captures do not establish workspace-wide replacement, exact match-range
navigation, local language tooling, or clean-machine installation.
