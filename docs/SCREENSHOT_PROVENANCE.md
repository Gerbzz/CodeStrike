# Historical default-editor screenshot provenance

This retained image documents the limited default root editor. The README now showcases the separately prepared Lapce branding candidate with [its own capture provenance](NATIVE_BRANDING_CAPTURES.md); the two implementations are not interchangeable.

The retained historical screenshot `assets/screenshots/codestrike-editor.png` is an uncomposited 1320 × 790 image from the Windows desktop application's built-in `--capture` path. Its SHA-256 is `4891CDFF38C86A56F6F1A4381A8C32E5EE7F12BC559C1EEE4B6BBCE978361ED2`.

The retained `codestrike-desktop.exe` used for capture has SHA-256 `738FAC75BD795EAF5A4454CE8BED21330088072E4370996B1140E82F13273624`. Its depfile names `src/bin/desktop.rs`, `src/lib.rs`, and `src/process_scope.rs`; all three file blobs match the public CodeStrike repository at this update. The app opened a small self-authored local Rust workspace containing `Cargo.toml`, `src/main.rs`, and `src/route.rs`. The relative workspace path in the image is a capture fixture, not a user or client path. The app's capture mode rendered the window and exited.

This verifies a bounded startup and source display. Search, edit/save, recovery, and Cargo action controls were not exercised in this capture; the README's separate workflow statements reflect earlier source and engineering review. No fresh build, Cargo check, test suite, or dependency download was run for this documentation update. The sample workspace itself is not distributed with the repository.
