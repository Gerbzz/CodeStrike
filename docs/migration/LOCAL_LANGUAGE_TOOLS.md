# Local Rust language tooling assessment - 2026-10-16

Status: **one opt-in Windows diagnostic path verified**. Completion,
definition, code actions, absent-server behavior, and distribution remain
unverified.

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

Next, test nonempty completion, go-to-definition and code actions through
the GUI, and verify clear behavior when the server is absent. Keep any
dependency acquisition within free hosted build constraints and the office
20 GiB free-space floor. A release would also need an explicit plugin
distribution and notice decision; the current test does not make one.
