# CodeStrike geometric identity

Original vector geometry created for the Strike noncreative family on 21 October 2026.

Purpose: Local source editing and Rust workflows. Symbol: Paired source scopes surround a live insertion rail.

The SVG is the master. The PNG and multiresolution ICO are direct renders of that SVG; no raster source was traced, edited, or used to create the replacement. No stock icon, font glyph, initial tile, or third-party brand geometry is used.

Original artwork and provenance remain at their original paths, unchanged. Publisher PWDS assets are unchanged. New files keep their own names and do not overwrite historical artwork.

This branch changes branding references, native icon resources, and their verification only. It preserves the original artwork and the pinned Lapce foundation. It does not change editor behavior or provide a release.

Asset verification: transparent corners and centered alpha bounds at 16, 24, 32, 48, 64, 128, 256, 512 and 1024 px. Small-size, light/dark and monochrome render proofs are in the task's deliverable pack.

The dependency-free resource helper embeds the multiresolution ICO into both the original `codestrike-desktop` preview and the selected Lapce-based `lapce` executable (normally copied to `CodeStrike.exe`). `scripts/prepare-lapce.ps1` applies the tracked native-branding patch without changing the pinned submodule commit. The selected foundation also uses this mark in its start view and About panel, and loads its native window icon from embedded resource 1 on Windows.

The native wrapper belongs to the pinned Lapce workspace-root package, which owns the `lapce` binary. Its entry source happens to live under `lapce-app/src/bin/`; adding a build script to the `lapce-app` library package does not attach the resource to the selected executable.

The branding workflow checks reviewed assets and the unchanged historical PNG, prepares and formats the pinned source, requires Windows resource compilation with `STRIKE_REQUIRE_ICON=1`, and verifies all seven embedded icon PNG payloads against the reviewed ICO. It captures genuine native startup and About views with isolated application data, records the exact source and executable hashes, and uploads evidence for independent visual review. The workflow does not publish an executable or installer. Successful checks and their limits belong in the PR verification record.

The native window probe checks the small window icon set by the pinned Floem/winit API. PE resource verification covers packaged icon bytes; it does not establish Windows taskbar or Room appearance. Those surfaces remain unverified.
