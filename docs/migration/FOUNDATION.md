# CodeStrike editor foundation decision - 2026-10-15

Status: **draft pinned source migration, not a shipped editor**. This remote draft starts at
CodeStrike commit `f340189b21e5a6b4002f5bdbbea5d8a69a67d672`. The existing
Rust source, tests, README, settings, and approved branding assets remain in
place. `editor/lapce` is a submodule pinned to source commit
`b012cef466741528f338879fa708355217fc40bd` (v0.4.6); the CodeStrike delta
is `editor/patches/codestrike-lapce.patch`, applied by `scripts/prepare-lapce.ps1`.
The submodule preserves upstream history, license, and lockfile. The patch uses
the existing approved CodeStrike PNG rather than replacing artwork.

## Product contract

CodeStrike is to become a practical local developer editor for Windows. A
usable first release must open real folders and files, keep multiple tabs,
save and reopen edits, navigate search results to the match, offer safe
search/replace, and connect to local language servers. The working window
must prioritize code; the CodeStrike name and approved mark belong on a
polished startup and About surface. Category-specific ArtCraft marks are a
later deliberate design change. Do not delete or silently substitute current
brand assets or user settings.

VS Code and Notepad++ are interaction and reliability benchmarks. Rust remains
the preferred implementation language. REA is only justified for a specific
behavior not established by source inspection; no REA work is needed for this
foundation choice.

## Evidence and choice

| Candidate | Source and platform evidence | Fit and cost |
| --- | --- | --- |
| Current CodeStrike | `src/bin/desktop.rs` has one `Document`, one `buffer`, and one `egui::TextEdit::multiline`. `open_file` refuses a second file while dirty. README lists absent tabs, syntax highlighting, result-to-caret navigation, replace preview, and rust-analyzer. | Keep its tested rope/search/file-safety/Cargo behavior as reference; extending this UI to full editor quality would rebuild mature editor subsystems. |
| **Lapce v0.4.6 - selected** | [Repository and Apache-2.0 license](https://github.com/lapce/lapce); [v0.4.6 release](https://github.com/lapce/lapce/releases/tag/v0.4.6) provides Windows builds. Source has [path/folder startup](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/app.rs), [editor tabs and splits](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/main_split.rs), [open-file and save-all commands](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/window_tab.rs), [workspace/window persistence](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/db.rs), and an [About popup](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/about.rs). The README identifies Floem, rope editing, LSP, terminal, and plugins. | Strongest compatible Rust foundation for a distinct ArtCraft editor. Apache-2.0 permits a controlled fork with preserved notices. Search/replace and LSP behavior still require direct Windows interaction tests before advertising them. |
| Zed | [Source README](https://github.com/zed-industries/zed) confirms Windows and primarily GPL-3.0-or-later source with marked Apache components; [Windows docs](https://zed.dev/docs/windows) give installation and GPU requirements. [Workspace source](https://raw.githubusercontent.com/zed-industries/zed/main/crates/workspace/src/workspace.rs) has save-all and multi-pane commands. | More complete editor today, but a branded distributed fork would inherit GPL obligations and a broad services/extension surface. This is a product/licensing choice, not a claim that Zed lacks the required UX. |
| Helix | [Source README](https://github.com/helix-editor/helix) documents MPL-2.0, tree-sitter, LSP and a primarily terminal/modal interaction model. | Excellent editing core, but a GUI matching the requested Windows workflow would be a separate major product. |

Pinned Lapce source and the patch are in the draft branch. This does **not**
establish the listed features as tested CodeStrike features. The selection is
based on inspected source boundaries and license/platform evidence, not an
end-to-end product test.

## Migration layout and sequence

1. The remote branch was created from `main` at `f340189`, eight commits
   after the local source snapshot `025b50b`. The intervening changes only
   modified README and added approved branding/screenshots, according to the
   GitHub commit comparison. Recheck `main` before any later integration.
2. The exact Lapce `v0.4.6` source is pinned in `editor/lapce/` with its
   `LICENSE`/notices and lockfile intact. The root CodeStrike app remains the
   default launcher; the candidate entry point is Lapce's desktop binary.
3. The patch gates known automatic network
   calls: `PluginData::new` [loads the remote plugin catalogue immediately](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/plugin.rs),
   and `app.rs` [starts a grammar/query release fetch](https://raw.githubusercontent.com/lapce/lapce/v0.4.6/lapce-app/src/app.rs)
   plus a feature-gated updater. The patch also changes the global settings
   namespace to `com/ArtCraft/CodeStrike` and workspace configuration/run files
   to `.codestrike/`. Continue auditing config, telemetry and
   language-server launch paths. Default CodeStrike to local files and
   explicitly chosen local language tools. Do not add hosted accounts,
   credentials, or automatic network services as part of branding.
4. The patch brands title, CLI, a no-workspace startup surface, and About,
   embedding the approved logo in startup/About. Startup interaction and
   visual quality still need a Windows GUI test. The new namespace is separate;
   settings migration/copy with a reversible backup
   and tested rollback remains pending. Keep brand out of working chrome unless
   user testing shows a clear purpose.
5. The patch ports CodeStrike's conflict guard, backup collision check, and
   temporary-file save to Lapce's proxy buffer. Hosted tests must verify the
   new behavior; crash recovery and GUI conflict messaging remain pending.
   Use focused adapters and tests; do not replace
   Lapce's rope, tabs, palette, explorer, search, or LSP with the old text box.
6. Run the acceptance matrix in `ACCEPTANCE.md`. Only after a tested Windows
   editor exists should the default launcher switch to it. Keep the old
   implementation available in the draft branch and retain the Git history.

## License, build, and publication gates

- Preserve Lapce's Apache-2.0 license, copyright and NOTICE if present, and
  generate third-party notices from the exact build graph before binary
  distribution. Existing CodeStrike has no explicit first-party license grant
  in this snapshot; resolve that separately rather than asserting a blanket
  license for combined files.
- Do not import Lapce or other logos as CodeStrike marks. Keep approved
  CodeStrike/PWDS artwork in place until an asset-by-asset branding decision.
- Lapce is a multi-crate Rust workspace with pinned Git Floem dependencies
  ([workspace manifest](https://github.com/lapce/lapce/blob/master/Cargo.toml)).
  Source checkout and Rust build can use far more disk than the release
  download. No local build, dependency download, or broad clone while the
  office machine's 20 GiB free-space floor and SkinStrike build slot apply.
- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
  states standard hosted runners are free for public repositories; larger
  runners are charged. Public draft PR #1 has a `windows-latest` workflow with
  a 45-minute limit, no cache/artifact upload, and read-only repository token.
  The first run found and fixed Windows CRLF patch application. The second run
  [compiled and passed CLI smoke tests](https://github.com/Gerbzz/CodeStrike/actions/runs/38712789811)
  in 5m48s, with 27.84 GiB free on the runner afterward. The
  [expanded startup/settings patch](https://github.com/Gerbzz/CodeStrike/actions/runs/38714317402)
  compiled in 7m51s and passed CLI smoke tests; its GUI probe watched the
  short-lived launcher, so that step must be rerun with `--wait`. The save
  safety patch and focused tests are part of the next hosted run.
- Keep the draft PR unmerged until the acceptance gates pass. The old editor
  remains the default launcher throughout this migration.
