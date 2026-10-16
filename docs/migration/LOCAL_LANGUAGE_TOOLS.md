# Local Rust language tooling assessment - 2026-10-16

Status: **opt-in Windows diagnostics, one saved completion, and a visible
missing-server error verified**. Definition, code actions, and distribution
remain unverified.

Pinned Lapce v0.4.6 routes language tooling through local Volt plugins.
`lapce-app/src/app.rs` accepts repeated `--plugin-path` arguments for
explicit local plugin paths. `lapce-proxy/src/plugin/wasi.rs` discovers and
loads those paths. A Volt can request `StartLspServer` in
`lapce-proxy/src/plugin/psp.rs`, which calls `LspClient::start` in
`lapce-proxy/src/plugin/lsp.rs` with a server URI and arguments. This is a
concrete route for an explicitly chosen local Rust plugin and a local
`rust-analyzer` executable. A server executable by itself does not activate
Rust support in this architecture.

The office PATH contains a rustup shim for `rust-analyzer`, but the component
is not installed there. No office build or component download was made. The
hosted Windows [run 38738590545](https://github.com/Gerbzz/CodeStrike/actions/runs/38738590545)
also found a shim without the component.

The official Apache-2.0 [Lapce Rust Volt](https://github.com/lapce/lapce-rust)
was inspected and pinned for CI to commit
[`ea1c8da7`](https://github.com/lapce/lapce-rust/commit/ea1c8da7df318a253edf07bd2862d236951b6d80),
version `0.3.3049`. Its source uses `serverPath` when supplied; the empty
default would download the latest rust-analyzer binary. The CodeStrike test
sets `serverPath = "rust-analyzer"` in a disposable workspace's
`.codestrike/settings.toml` and installs the component explicitly on the
standard hosted runner. The plugin is loaded with `--plugin-path`; it is not
bundled, enabled by default, or fetched by CodeStrike. The CI copy retains
the Volt's license alongside its WASM file.

[Windows run 38953240177](https://github.com/Gerbzz/CodeStrike/actions/runs/38953240177),
job `117149602450`, passed on code commit `046f0baff78e1015fa3759de2f51e89bdf5652ab`.
The runner used rust-analyzer `1.99.0 (b940084d 2026-09-28)` and built the
pinned Volt to a 1,159,617-byte WASM file. The actual CodeStrike GUI opened a
disposable Rust Cargo workspace. The proxy sent `initialize` and `didOpen`,
received the server capabilities, and received `textDocument/publishDiagnostics`
with error `E0308` for an intentionally wrong `i32` assignment. The hosted
probe checked those messages from captured proxy output and closed the app
cleanly. Its screenshot shows the open Rust file and one error indicator.
The runner had 27.35 GiB free after the debug build. This verifies a local,
explicitly selected server and one diagnostic case, not the full language
tooling row in [ACCEPTANCE.md](ACCEPTANCE.md).

[Windows run 38956274211](https://github.com/Gerbzz/CodeStrike/actions/runs/38956274211)
confirmed a real GUI caret inside `use std::io::Read;` and a passing E0308
diagnostic, but the advertised `get_completion` shortcut sent no LSP request.
The pinned Floem editor-core command enum contains `GetCompletion`, while
Lapce v0.4.6's `run_focus_command` did not handle it. The isolated CodeStrike
patch now calls the existing `update_completion(true)` path for that command.
[Windows run 38957477121](https://github.com/Gerbzz/CodeStrike/actions/runs/38957477121),
job `117163870747`, passed all steps on commit
`e9a1e8e9348eb9fb29dd3883c9603f905e97890f`. In the actual GUI, the
probe invoked completion at the Rust import, the proxy logged
`textDocument/completion`, the server returned a `Read` item, and the
app-window screenshot shows a nonempty completion menu with `Read`.
The E0308 diagnostic also passed in this run. This verifies one completion
request/response and visible menu, not insertion of a selected item or
other language-tooling behaviors.

[Windows run 38959531604](https://github.com/Gerbzz/CodeStrike/actions/runs/38959531604),
job `117170803799`, passed every step on follow-up code commit
`a081c5864171345cdc63c739aaad6584459b4cae`. The GUI opened a Rust
file with the incomplete import `use std::io::Re;`, requested completion,
displayed `Read` at the top of the menu, selected it, and saved the exact
expected bytes containing `use std::io::Read;`. An E0308 diagnostic passed
again. This is targeted regression coverage for the new `GetCompletion`
handler and one completion insertion, not every Rust completion shape.

The same run explicitly set the pinned Volt's `serverPath` to a unique
nonexistent executable. Source inspection confirms this configuration takes
the plugin's local-server branch, avoiding its automatic download branch.
The candidate proxy now forwards a failed server launch to its existing UI
message channel. The app-window screenshot shows a visible error telling the
user to check the server path. CodeStrike remained open, and a completion
and save attempt left the Rust source's SHA-256 unchanged. The probe found
no LSP `initialize` message or downloaded `.gz` archive in the Volt folder.
This covers one explicitly configured unavailable-server case, not every
plugin failure, offline state, or recovery path.

Next, test go-to-definition and code actions through the GUI. Keep any
dependency acquisition within free hosted build constraints and the office
20 GiB free-space floor. A release would also need an explicit plugin
distribution and notice decision; the current test does not make one.
