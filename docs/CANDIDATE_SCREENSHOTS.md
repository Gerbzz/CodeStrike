# Draft editor screenshot provenance

These are byte-for-byte copies of unedited JPEG frames from the **unmerged
Lapce-based CodeStrike candidate** on draft PR [#1](https://github.com/Gerbzz/CodeStrike/pull/1).
They are shown in the public main-branch README to document work in progress;
they do not depict the application built from `main`. The Windows runner
desktop and terminal are visible around the editor. No crop, compositing, or
retouching was applied.

| Image on `main` | Source run and assertion | SHA-256 |
| --- | --- | --- |
| [Three tabs](../assets/screenshots/codestrike-candidate-tabs.jpg) | [Run 38724671470](https://github.com/Gerbzz/CodeStrike/actions/runs/38724671470), job `116387451149`, tested distinct saves in three tabs, graceful close, reopen, and further saves. | `11b1c81bc18acb43e58c7dd61c95726017a40f3069294fe92f298ea66ce4d91f` |
| [Workspace replacement preview](../assets/screenshots/codestrike-candidate-replace-preview.jpg) | [Run 38757901744](https://github.com/Gerbzz/CodeStrike/actions/runs/38757901744), job `116501116239`, compiled code commit `9a77ed67b69f0c8b0d483d9980a80379f7a62edb` and listed two matches before any write. | `319d50415340a9086517235a13441fdc2c2bfd7c6e6feb8991a63c09ddb5929e` |
| [Checked Undo](../assets/screenshots/codestrike-candidate-undo.jpg) | The same run refused Undo over a newer edit and then restored both originals after their expected applied bytes were restored. | `978f9b5c27ca2ce52ad21d4ecb0c40b49402ae2723686d975707b1ad36f103cb` |

The full [draft evidence index](https://github.com/Gerbzz/CodeStrike/blob/bee871db3ac79f2f6e54f062f0da0266884a6526/docs/migration/evidence/README.md)
includes the original logs, other GUI states, hashes, and known limits. This
README presentation added no build or feature verification. Crash
interruption, cross-session recovery, and clean-machine installation remain
untested.
