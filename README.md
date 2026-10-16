<p align="center">
  <img src="assets/branding/CodeStrike.png" alt="Original CodeStrike octopus mark" width="144" height="144">
</p>

<h1 align="center">CodeStrike</h1>

<p align="center"><strong>Stay close to your code.</strong><br>A local source editor for real folders, careful saves, and deliberate Rust workflows.</p>

<p align="center">
  <a href="https://prowebdevsolutions.com"><picture>
    <source media="(prefers-color-scheme: dark)" srcset="assets/branding/PWDS-logo-orange.svg">
    <img src="assets/branding/PWDS-logo.png" alt="PWDS company mark" width="116">
  </picture></a>
</p>

> **Windows engineering preview - source build only.** The default application is a working but limited native Rust editor. A more capable Lapce-based editor is included as a separately prepared [candidate](editor/UPSTREAM.md), developed in [PR #1](https://github.com/Gerbzz/CodeStrike/pull/1). Screenshots in the **Editor candidate** section show that candidate, not the default app. There is no CodeStrike installer or release yet.

<p align="center"><a href="#the-default-editor">Default editor</a> | <a href="#editor-candidate">Editor candidate</a> | <a href="#build-and-run">Build and run</a> | <a href="#status-and-roadmap">Status</a> | <a href="#source-and-attribution">Attribution</a></p>

![The CodeStrike main-branch Windows editor with a self-authored Rust sample workspace](assets/screenshots/codestrike-editor.png)

*The default application displaying a local Rust project. This retained, app-rendered capture does not claim that the visible Cargo controls were run; see [provenance](docs/SCREENSHOT_PROVENANCE.md).*

## The default editor

### Work in your own folders

Open a local folder, browse its files, and edit a UTF-8 source file. The interface shows the selected workspace, active file, dirty state, search results, and command output. The command-line companion can inspect status, insert text, search a workspace, and request explicit local Cargo checks.

### Save with a way back

CodeStrike checks the file on disk before saving, preserves a UTF-8 BOM and a consistent newline style, and writes a recovery snapshot after edits. Undo and Redo operate on the source model. Unsupported input, including invalid UTF-8, NUL-containing files, mixed newlines, and files over 20 MiB, opens read-only rather than being silently rewritten.

### Search, then choose what runs

Search the selected workspace with literal or regex patterns; a result opens its file. **Check**, **Build**, and **Test** show the local Cargo command and working directory and run only when pressed. Cargo is invoked offline without shell interpolation. A chosen project's build scripts and procedural macros can still execute, as with a normal Cargo build.

This default editor has **one active file**, no syntax coloring or line-number gutter, no result-to-caret navigation or replacement preview, and no verified language server, debugger, or accessibility pass. Its process controls are tested on Windows; non-Windows process execution currently refuses to start.

## Editor candidate

The [Lapce-based CodeStrike candidate](editor/UPSTREAM.md) keeps the original repository, settings, and artwork while developing the fuller editor workflow. It requires [patch preparation](scripts/prepare-lapce.ps1) and an explicit build; the root application remains the default. The images below are app-window crops from the verified Windows runs listed in [screenshot provenance](docs/CANDIDATE_SCREENSHOTS.md); [evidence-only commit `bee871d`](https://github.com/Gerbzz/CodeStrike/commit/bee871db3ac79f2f6e54f062f0da0266884a6526) published the full captures and test notes. The editor pixels were not altered.

### Real tabs and a restorable session

Three distinct source files were edited and saved, the app closed, and the same tabs reopened for further edits in the [Windows acceptance run](https://github.com/Gerbzz/CodeStrike/actions/runs/38757901744). Workspace search opened a clicked hit at its UTF-8 byte column. Per-file Replace All and save-conflict protection were also exercised.

![App-window crop of three tabs in the CodeStrike editor candidate](assets/screenshots/codestrike-candidate-tabs-app.png)

*Editor candidate, not the default application. [Full original capture and crop provenance](docs/CANDIDATE_SCREENSHOTS.md).*

### Preview a workspace change before writing

The editor candidate has a bounded multi-file replacement flow: preview paths, positions, context, and replacement text; confirm Apply; use Checked Undo while the session is open. The Windows GUI probe previewed two files without changing them, refused an Apply after an external edit, applied two replacements while preserving UTF-8 BOM/CRLF and LF bytes, refused Undo over a newer edit, and then restored the originals exactly. Ignored, read-only, and unsupported files were not changed.

![App-window crop of the two-file workspace replacement preview in the editor candidate](assets/screenshots/codestrike-candidate-replace-preview-app.png)

*Editor candidate, not the default application. [The checked Undo app-window crop](assets/screenshots/codestrike-candidate-undo-app.png) and [full original captures with hashes](docs/CANDIDATE_SCREENSHOTS.md) show the rest of this bounded test.*

The candidate still needs crash-interruption and cross-session recovery tests, automatic cleanup of visible backups, broader search/replace cases, local language-tool verification, accessibility review, and clean-machine installation. It is not yet a distribution.

## Build and run

### Default Windows preview

Install a Rust toolchain with Cargo, then from PowerShell:

```powershell
git clone https://github.com/Gerbzz/CodeStrike.git
cd CodeStrike
$env:CARGO_BUILD_JOBS = '1'
cargo test --locked --features desktop
cargo run --locked --features desktop --bin codestrike-desktop
```

Use **Open folder** and select a source file in Explorer, or choose **Open file**. Ctrl+S saves after the disk-version check. The first build needs dependency registry access; after dependencies are cached, Cargo's `--offline` flag is available. No prebuilt installer is published.

For the source CLI, run `cargo run --locked --bin codestrike -- --help`. Commands include `status`, `insert`, `find`, `replace`, `regex`, `recover`, `check`, `build`, and `test`. Workspace search scans at most 100 MiB and returns at most 500 hits. Cargo output has a ten-minute timeout and a 4 MiB cap per stream.

### Editor candidate from source

The candidate has its own pinned Lapce submodule and patch. On Windows, start with a fresh checkout and enough disk space for a Rust GUI build:

```powershell
git -c core.autocrlf=false clone --recurse-submodules https://github.com/Gerbzz/CodeStrike.git CodeStrike-candidate
cd CodeStrike-candidate
pwsh -File .\scripts\prepare-lapce.ps1
cargo build --manifest-path .\editor\lapce\Cargo.toml --locked --bin lapce
Copy-Item .\editor\lapce\target\debug\lapce.exe .\editor\lapce\target\debug\CodeStrike.exe
.\editor\lapce\target\debug\CodeStrike.exe --wait
```

This follows the [tested Windows workflow](.github/workflows/editor-candidate.yml); it is a developer build, not an installer. The latest full acceptance run measured a 103.75 MiB debug executable, but release and installed footprints have not been measured. If a checkout converts the pinned upstream source to CRLF, the patch preparation will refuse it; use a fresh LF checkout rather than applying the patch to modified files.

## Status and roadmap

| Area | Default editor | Editor candidate |
| --- | --- | --- |
| Local folders and files | Open, edit, guarded save; one active file | Three-tab save and reopen path verified on Windows |
| Search and replacement | Workspace search and per-file commands | Exact hit caret, per-file Replace All, bounded two-file preview/Apply/Undo verified |
| Language tooling | Explicit offline Cargo Check/Build/Test | Opt-in local rust-analyzer diagnostics, `Read` completion insertion/save, and a visible missing-server error verified in the candidate GUI on Windows; definition, code actions, and packaging pending |
| Distribution | Source build on Windows | Source build and CI only; no installer or release |

The [candidate acceptance matrix](docs/migration/ACCEPTANCE.md) records the tested cases and open gates. CodeStrike is still an engineering preview, not a VS Code replacement ready for everyday professional work.

## Source and attribution

The original CodeStrike and PWDS artwork above is retained. [Brand provenance](assets/branding/provenance.json) and [default-editor screenshot provenance](docs/SCREENSHOT_PROVENANCE.md) identify those assets. The editor candidate is based on pinned [Lapce v0.4.6](https://github.com/lapce/lapce/releases/tag/v0.4.6) under Apache-2.0; its license and source history remain in the submodule. [`THIRD_PARTY.md`](THIRD_PARTY.md) records the dependencies and donor audit for the default application.

No first-party license grant is stated for this checkout. Binary distribution would need notices verified against its exact contents.
