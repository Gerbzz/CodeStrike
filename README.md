# CodeStrike Windows engineering preview

CodeStrike now includes a native Rust source editor preview on its existing rope/search/Cargo core. Open a local folder and file, edit UTF-8 source, save or recover an interrupted edit, search the workspace, and run offline Cargo Check, Build, or Test explicitly from the Problems panel. The editor shows the selected workspace, active file, dirty state, search results, diagnostics, and command output. It preserves a file's BOM and consistent newline style, checks for external changes before save, and leaves unsupported files untouched.

Launch on Windows from this directory:

```powershell
$env:CARGO_BUILD_JOBS='1'
$env:CARGO_TARGET_DIR='..\target-codestrike'
cargo test --locked --features desktop
cargo run --locked --features desktop --bin codestrike-desktop
```

A fresh checkout needs registry access for its first dependency download. After the registry cache is populated, add `--offline` if an offline build is needed.

Choose **Open folder**, then select a file in Explorer or use **Open file**. Edit directly; a recovery snapshot is written after changes, and Ctrl+S or **Save** updates the source after checking its disk version. **Undo/Redo** uses the source model; a found search result opens its file. Check/Build/Test display the exact local Cargo argv and workspace cwd and run only when pressed. Cargo may execute the selected workspace's build scripts and procedural macros. `--workspace PATH --file PATH --capture FILE.png` is an app-rendered QA capture path.

Command line source workflow:

```text
cargo run --locked --bin codestrike -- status path/to/main.rs
cargo run --locked --bin codestrike -- insert path/to/main.rs 0 "// note"
cargo run --locked --bin codestrike -- find path/to/workspace symbol
cargo run --locked --bin codestrike -- check path/to/cargo-workspace
```

`replace`, `regex`, `recover`, `build`, and `test` are also available. Indexes and search columns count Unicode scalar values. Invalid UTF-8, binary/NUL, mixed newline, and files over 20 MiB open read-only. Search examines at most 100 MiB and returns at most 500 hits. Cargo uses `--offline` and no shell interpolation; checking a selected project may still execute that project's build scripts or proc macros, as normal Cargo does.

Current limits: one active file, no syntax colors or line-number gutter, result-to-caret navigation, replace preview, rust-analyzer, debug adapter, or accessibility pass. Cargo runs off the UI thread with a Cancel control, ten-minute timeout, and 4 MiB capture cap per output stream. Windows runs the command in its own kill-on-close Job Object; a controlled fake Cargo child and a real Cargo build-script child were both stopped on cancellation. Non-Windows process execution currently refuses to start until equivalent lifecycle cleanup is tested. Source and recovery writes use exclusive transaction files and refuse changed recovery/source content; existing sidecars are preserved. Search bounds and file refusal remain as described above. The pinned VectorCraft UI donor's palette/dock code depends on its illustration engine and egui 0.36; no code from that UI has been copied. Windows is the only tested platform. Planning history and QA captures are not included in this standalone source checkout.

## Source terms

No first-party license grant is stated for this app in this checkout. `THIRD_PARTY.md` records attribution for identified upstream material; the included donor license files, where present, apply to that material.
