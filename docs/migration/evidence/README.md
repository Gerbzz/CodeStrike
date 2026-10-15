# CodeStrike Lapce candidate: Windows GUI captures

These are unedited JPEG frames decoded from the `CODESTRIKE_SCREENSHOT_*_BASE64`
markers in [hosted Windows run 38720659614](https://github.com/Gerbzz/CodeStrike/actions/runs/38720659614),
job `116374116215`. The run compiled draft commit
`73b8346d261d450a4021fcfc6e0af08cc8285893` on `windows-latest`.
The images show the **new pinned-Lapce candidate**, not the original CodeStrike
launcher or a release package. They include the runner desktop and terminal;
the window is not maximized. No image edits, crops, or composites were made.

| Capture | What the frame verifies | SHA-256 |
| --- | --- | --- |
| [Startup](startup.jpg) | Approved CodeStrike mark, name, Open folder and Open file actions in a running window. | `1d8c909839c4029c2259ce3301f1e0636ad685e811228ce04e14c204e697621d` |
| [Folder](folder.jpg) | Explorer lists a synthetic folder containing `main.rs` and `notes.txt`. | `97e2bb662e80530a894516585fe987361219b2ccb0390d57e5bcef02dcfbb95b` |
| [Editor](file.jpg) | `main.rs` is a tab and displays the keyboard-inserted `codestrike_ci_saved` marker. The run separately asserted Ctrl+S wrote the marker to disk. | `2fde71ddca1cfd2d6ccbe373677fe5c35155d20e2fb4f003aff92d2f35f39aa9` |

The fixture was created under the hosted runner's temporary directory by
[`scripts/probe-windows-editor.ps1`](../../../scripts/probe-windows-editor.ps1).
These captures do not prove session restoration, multi-file editing,
search/replace, local language tooling, or clean-machine installation.
