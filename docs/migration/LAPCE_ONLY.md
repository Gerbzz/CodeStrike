# Lapce-only cutover

Boundary reviewed against main `6d97fe3bca09793ba49dbd848365a2a98f5098c1`.

## Retired

Only the predecessor `src/bin/desktop.rs` GUI and its eframe/rfd/png target dependencies are removed. No history is rewritten. The former source-model CLI is byte-for-byte moved to `tools/core-cli.rs` and explicitly named `codestrike-core-tool`, a developer utility rather than a second editor. Its integration test remains and invokes that renamed target.

## Preserved

- `editor/lapce` gitlink `b012cef466741528f338879fa708355217fc40bd`, `editor/UPSTREAM.md`, exact CodeStrike Lapce patch and preparation guard.
- `src/lib.rs`, `src/process_scope.rs`, their save/recovery/search/process support and tests. Inspection of the Lapce patch found no root-crate dependency, but retaining these prevents losing reusable work.
- All candidate probes, acceptance records, screenshots and licenses. Historical captures are not represented as current-head runtime acceptance.
- Reviewed rust-analyzer source patches, test hooks and all analyzer CI/probes.
- All remote branches unchanged. `draft/local-agent-adapter` at `03a3c22d45f692efe2b1a659d4e34d8cd2e7a687` contains `src/agent_adapter.rs`, `agent_panel.rs`, `agent_review.rs`, `agent_session.rs`, their tests and an extended Lapce panel patch. It is an existing open-source-base donor, not obsolete predecessor work. Its own documentation says the panel is not yet compiled/runtime accepted. It must be integrated by a separately reviewed change, not silently overwritten.

No Delta-named public branch was found in the branch inventory. This does not establish that local/unpublished Delta work is absent. That work and the separate Delta reference capture remain dependencies; this cutover implements no Delta features.

## Default route and evidence

`scripts/build-codestrike.ps1` prepares the existing pinned patch then builds the actual Lapce binary. Use `-Prepared` only for a previously prepared checkout; the default preparation rejects dirty source and never resets it. `-Release` selects the release profile. The root `codestrike` launcher routes solely to debug Lapce or the explicit `CODESTRIKE_EDITOR` executable, forwarding arguments without a shell. Missing builds fail; there is no fallback to the retired GUI.

The existing editor workflow now runs for main pull requests, retaining all save/conflict/replacement/tab/search/encoding/reload acceptance steps. Its concurrency group is per PR/ref, not a suite-wide build slot. Separate cutover CI tests source preservation and launcher delegation. Native build/runtime results must be checked on the exact PR head before merge.

`BASELINE.sha256` and `verify-baseline.ps1` describe the historical predecessor snapshot, not the current product. They are retained as history, not used as the cutover acceptance gate. `scripts/tests/test_lapce_cutover.py` checks the preserved donors against the exact cutover base.
