# Local Rust language tooling assessment — 2026-10-15

Status: **source route identified; diagnostics and completion not verified**.

Pinned Lapce v0.4.6 routes language tooling through local Volt plugins.
`lapce-app/src/app.rs` accepts repeated `--plugin-path` arguments for
explicit local plugin paths. `lapce-proxy/src/plugin/wasi.rs` discovers and
loads those paths. A Volt can request `StartLspServer` in
`lapce-proxy/src/plugin/psp.rs`, which calls `LspClient::start` in
`lapce-proxy/src/plugin/lsp.rs` with a server URI and arguments. This is a
concrete route for an explicitly chosen local Rust plugin and a local
`rust-analyzer` executable. A server executable by itself does not activate
Rust support in this architecture.

The office PATH contains `C:\Users\Neil\.cargo\bin\rust-analyzer.exe`, but
`rustup which rust-analyzer` returns `unknown binary 'rust-analyzer'` and
`rustup component list --installed` does not list it. The hosted Windows
[run 38738590545](https://github.com/Gerbzz/CodeStrike/actions/runs/38738590545)
likewise found a rustup shim on PATH and no installed component. This draft
does not pin a Rust Volt. No verified Rust server/plugin pair was therefore
available for a meaningful diagnostics/completion test. The draft leaves
automatic plugin catalog and grammar release fetching disabled; no new
download, executable auto-discovery, or trust expansion was added for this
assessment.

Before claiming language tooling, provide an approved, locally installed
`rust-analyzer` executable and a pinned, license-reviewed Rust Volt that
starts it. Then test completion, diagnostics, go-to-definition and code
actions against a disposable Rust workspace, including clear behavior when
the server is absent. Record the exact executable/plugin versions and GUI
evidence. Keep any dependency acquisition within the free hosted build
constraints and the office 20 GiB free-space floor.
