# Pinned editor foundation

`editor/lapce` is a Git submodule pinned to Lapce v0.4.6, commit `b012cef466741528f338879fa708355217fc40bd` (annotated tag object `a54a1bb875e3e2cb5b39638cc72c1fa732923625`). The full upstream source, history, `LICENSE` (Apache-2.0), and dependency lockfile remain in the submodule. See https://github.com/lapce/lapce/tree/v0.4.6.

Lapce is CodeStrike's only supported editor foundation. The root Rust executable launches the prepared Lapce-based native editor; it is not the retired desktop application. Historical desktop work remains in Git history, while approved assets are preserved. Build patches in `editor/patches` retain the original donor patch and apply separate formatting, language/save-capability, completion-observation and geometric-branding overlays. Windows acceptance scripts remain in `scripts`.

The editor's Rust source lives inside this pinned submodule. GitHub's parent-repository language summary does not expand submodule contents; the Python and PowerShell tooling in this repository is not a replacement editor implementation.
