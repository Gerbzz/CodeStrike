# CodeStrike native branding candidate captures

These unchanged PNGs show the **Lapce-based branding candidate**, not the default root editor, an installed Room app, or a release. The earlier default-editor and workflow screenshots are retained as historical evidence in [default provenance](SCREENSHOT_PROVENANCE.md) and [candidate history](CANDIDATE_SCREENSHOTS.md).

## Build and capture source

- Repository commit: [`e61517b15f09f6860a06595fda44ca73c87f8d68`](https://github.com/Gerbzz/CodeStrike/commit/e61517b15f09f6860a06595fda44ca73c87f8d68), PR [#8](https://github.com/Gerbzz/CodeStrike/pull/8).
- Full source tree: `09f32b3cf45bc0da454e9d4c752c9c584ddae389`.
- Native build and capture: [run 39693959159, job 119546707393](https://github.com/Gerbzz/CodeStrike/actions/runs/39693959159/job/119546707393), successful on Windows GitHub Actions.
- Executable SHA-256: `eeb2fe60fa0936bc11a2f8088531d25298f5293e186df3cb7253c5b6830ae63b`.
- Original scoped artifact: `12389859273`, archive SHA-256 `4e34cd749fbab4854e529ebfd159ebde993c07787957f618f804b765910c090e`. Artifact retention is short; the original PNG bytes below are preserved in the repository.

| Original native PNG | Size | SHA-256 |
| --- | --- | --- |
| [Startup](../assets/screenshots/codestrike-native-startup-2026-10-21.png) | 984 × 688 | `4d5e4c04116348732ae82abe33fc88357a80a987e4bfccdc5ee76f6b56b82f4e` |
| [About](../assets/screenshots/codestrike-native-about-2026-10-21.png) | 984 × 688 | `12e9c1c2d3eecddcf64886bf71d765bb69f1dc393e867cb0dc9fe7988e05c0d7` |

No pixels were cropped, rescaled, composited, generated or otherwise edited. These are actual captured application client pixels, including CodeStrike's custom chrome. The startup view is empty with an idle integrated terminal on a disposable runner; it contains no private workspace. About preserves the visible Lapce Apache-2.0 and Codicons attribution.

The native check passed all seven exact executable icon payloads. It selected the owned visible CodeStrike GUI window and proved that its real 32-pixel small-window icon pixels match the reviewed ICO. The appearance review found the mark and app name readable and the About credits unclipped.

This does not establish Windows shell/taskbar appearance, Room acceptance, installation, editing, completion or language-server acceptance. The separate [language-tools run at this capture commit](https://github.com/Gerbzz/CodeStrike/actions/runs/39693959143) failed bounded completion-response readiness, although genuine E0308 diagnostics and fixture completion requests were observed. That independent failure was not bypassed by the successful branding capture.
