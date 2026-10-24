# Current geometric CodeStrike native captures — 24 October 2026

These are genuine unedited startup and About client-area captures of the selected
Lapce-based CodeStrike source build, not the retired custom editor. The existing
reviewed geometric identity is reused from PR #8; no new artwork was generated.

## Exact source and native proof

- Source: [`a5f77b95794ba2413548fd99c3e9124899853008`](https://github.com/Gerbzz/CodeStrike/commit/a5f77b95794ba2413548fd99c3e9124899853008), tree `ef8ef1e4f507a3677a2863bf36f1bf911f12dce9`, integration [PR #14](https://github.com/Gerbzz/CodeStrike/pull/14).
- Fresh Windows capture: [run 40054421622, job 120754117518](https://github.com/Gerbzz/CodeStrike/actions/runs/40054421622/job/120754117518).
- Executable SHA-256: `e3183ba3826209ee0b3a1a78321f73bae9b5cecab5da88452abe7806abe475f5`.
- Artifact `12544263631`, archive SHA-256 `3c3ff69d43ea3b19a3a651149f4a759cf76d2015cb59e82ca50f4d6941baca66`.
- Existing reviewed PNG SHA-256: `bc52e0a0ff2ee6553f6d8bf9c91e92d044cf742532db8611320ecd0a621a1c80`.
- Existing reviewed ICO SHA-256: `8a4d0e28a801bcf6c552d739ee0c67aec99de5e3265e8aa2a51829d4d3f84d79`.

| Fresh native capture | Size | SHA-256 |
| --- | --- | --- |
| [Startup](../assets/screenshots/codestrike-native-startup-2026-10-24.png) | 984 × 688 | `4d5e4c04116348732ae82abe33fc88357a80a987e4bfccdc5ee76f6b56b82f4e` |
| [About](../assets/screenshots/codestrike-native-about-2026-10-24.png) | 984 × 688 | `12e9c1c2d3eecddcf64886bf71d765bb69f1dc393e867cb0dc9fe7988e05c0d7` |

The probe captured the owned visible editor with `CopyFromScreen`, from an isolated
empty application profile. The PNGs were copied directly from the fresh artifact,
without compositing, scaling, cropping after capture, recoloring, or other pixel edits.
They happen to be byte-identical to the [earlier dated captures](NATIVE_BRANDING_CAPTURES.md),
which show the same static UI and identity; the new run and executable/source proof
establish the fresh observation. Earlier captures remain separately preserved.

The hosted verifier required all seven ICO image payloads (16–256 px) in the selected
executable and exact pixel equality for the live native small-window icon. Independent
visual inspection found the geometric mark, CodeStrike name and attribution readable.

This establishes splash/About/resource/window-icon alignment, not Windows taskbar,
Room appearance, clean-machine installation, release packaging, or complete app parity.
Editing and reviewed Rust language behavior have separate mandatory native gates.
The historical octopus artwork is retained only for provenance; no current splash,
About view, native icon, or README header selects it.
