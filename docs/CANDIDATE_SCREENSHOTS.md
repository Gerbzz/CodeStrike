# Historical editor candidate screenshot provenance

These are earlier workflow captures, preserved as historical test evidence. The [current native branding candidate captures](NATIVE_BRANDING_CAPTURES.md) are the README showcase; they remain separate from the default root app.

The full JPEG frames below are byte-for-byte copies from the **Lapce-based
CodeStrike candidate** developed in PR [#1](https://github.com/Gerbzz/CodeStrike/pull/1).
They do not depict the default root application. The original frames
include the Windows runner desktop and terminal. The README displays
deterministic app-window crops while retaining every full original here.

| Image on `main` | Source run and assertion | SHA-256 |
| --- | --- | --- |
| [Three tabs](../assets/screenshots/codestrike-candidate-tabs.jpg) | [Run 38724671470](https://github.com/Gerbzz/CodeStrike/actions/runs/38724671470), job `116387451149`, tested distinct saves in three tabs, graceful close, reopen, and further saves. | `11b1c81bc18acb43e58c7dd61c95726017a40f3069294fe92f298ea66ce4d91f` |
| [Workspace replacement preview](../assets/screenshots/codestrike-candidate-replace-preview.jpg) | [Run 38757901744](https://github.com/Gerbzz/CodeStrike/actions/runs/38757901744), job `116501116239`, compiled code commit `9a77ed67b69f0c8b0d483d9980a80379f7a62edb` and listed two matches before any write. | `319d50415340a9086517235a13441fdc2c2bfd7c6e6feb8991a63c09ddb5929e` |
| [Checked Undo](../assets/screenshots/codestrike-candidate-undo.jpg) | The same run refused Undo over a newer edit and then restored both originals after their expected applied bytes were restored. | `978f9b5c27ca2ce52ad21d4ecb0c40b49402ae2723686d975707b1ad36f103cb` |

Each source frame is 960 × 720 pixels. The README crops use the identical
rectangle **x=0, y=0, width=750, height=560**, matching the visible editor
window. A lossless PNG stores the decoded pixels in that rectangle; the app
controls and status bar remain in frame. No scaling, compositing, or generated
pixels were used.

| README crop | Source frame | Crop SHA-256 |
| --- | --- | --- |
| [Three tabs, app only](../assets/screenshots/codestrike-candidate-tabs-app.png) | [Full tabs frame](../assets/screenshots/codestrike-candidate-tabs.jpg) | `3cc2acdfd2ea0d4af33208cd6960fc9d62c71e4568583c2349f74e2b0b848131` |
| [Replacement preview, app only](../assets/screenshots/codestrike-candidate-replace-preview-app.png) | [Full preview frame](../assets/screenshots/codestrike-candidate-replace-preview.jpg) | `15c36f66d7ee76dd659fe2433a9f487bce606f56286ea4d3b32c65e4e4dd2617` |
| [Checked Undo, app only](../assets/screenshots/codestrike-candidate-undo-app.png) | [Full Undo frame](../assets/screenshots/codestrike-candidate-undo.jpg) | `026e996f18628c8e58a2d05d381cac3a3ed08791fe21a851ddf5c124948c0a8c` |

The full [draft evidence index](https://github.com/Gerbzz/CodeStrike/blob/bee871db3ac79f2f6e54f062f0da0266884a6526/docs/migration/evidence/README.md)
includes the original logs, other GUI states, hashes, and known limits. This
README presentation added no build or feature verification. Crash
interruption, cross-session recovery, and clean-machine installation remain
untested.
