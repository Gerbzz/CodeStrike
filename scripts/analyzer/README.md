# Reviewed analyzer CI gates

`prepare-reviewed-source.ps1` verifies the immutable upstream commit, the reviewed patch, the lockfile, and the exact eight changed source paths before building. `-WithTestHooks` adds deterministic acknowledgements only in the separate race job. That job's binary is never used by the native GUI.

`race_gates.py` drives real LSP sessions on disposable Cargo fixtures. It requires acknowledgement of each injected cancellation and both diagnostic slices, then holds the final document for 15 seconds. The save-order cases hold an older worker until a newer save or explicit Cancel is processed and require the old restart to be rejected. The hooks are narrowly scoped to synthetic files under the job's temporary directory.

`quickfix_gates.py genuine` uses actual `cargo check`/rustc JSON from a two-file project. Rustc's suggested lifetime fix has three edits, all in `main.rs`; the action must disappear after an unsaved edit of that file. `quickfix_gates.py synthetic` uses the explicitly named test emitter to produce one suggestion touching `main.rs` and `lib.rs`; an unsaved edit of `lib.rs` must invalidate that cached action. The synthetic result is a cross-file cache lifecycle test, not proof of a real rustc cross-file suggestion.

The normal LSP step executes nine final-state scenarios, then audits every versioned push publication for source, code, range, and ordering. It also runs pull, disabled-push, and disabled-pull capability gates. Each case uses a fresh fixture, pinned compiler source, and a bounded hold. `rust-toolchain-guard.ps1` checks the single exact `rustc -vV` commit line and the process exit code; its focused test covers correct, wrong, missing, and duplicate hash lines.

The native strict and recovery scripts open only generated Rust fixtures with isolated `APPDATA` and `LOCALAPPDATA`. The strict gate requires exact saved bytes and zero errors at valid version 3, then restored E0308 and completion. The recovery gate checks that the missing server reports an error without an unrequested edit or unexpected `Volt.gz` archive, then verifies recovery. `capture-code-window.ps1` stores app-window screenshots in the disposable runner directory and logs only their path and SHA256. No screenshot pixels or base64 are written into public CI logs.

CodeStrike #4's failed standalone and GUI runs are historical controls. This workflow's path filter does not rerun those unchanged files; candidate CI results are separate from a fresh matched stock control.
