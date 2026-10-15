# CodeStrike Windows Acceptance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce repeatable Windows evidence for the pinned Lapce candidate's multi-file session, search/replace, and GUI save conflict behavior.

**Architecture:** A PowerShell harness creates disposable files and isolated CodeStrike configuration on the standard hosted Windows runner, drives the real GUI, asserts disk outcomes, and emits bounded screenshots. Keep feature fixes in the pinned patch so the upstream submodule remains intact.

**Tech Stack:** PowerShell, Win32 input and window APIs, Lapce v0.4.6 Rust source, GitHub Actions `windows-latest`.

**Spec:** `docs/migration/FOUNDATION.md` and `docs/migration/ACCEPTANCE.md`.

## Global Constraints

- Preserve the original CodeStrike files, artwork, settings, and launcher.
- Keep `draft/lapce-foundation-migration` isolated and PR #1 unmerged.
- Use synthetic files only; keep upstream network fetches default-off and existing licenses/notices intact.
- Use standard free hosted CI only, no local build or large download, and keep at least 20 GiB free on the office drive.
- Label every new image as the Lapce candidate with its run, commit, fixture, and SHA-256.

## Review Focus

- A tab shortcut must edit the selected file, not a terminal or hidden editor; assert three distinct files on disk.
- Graceful close and reopen must recover all three files; assert a second distinct edit to each after restart.
- Search must expose the expected synthetic matches; record a GUI capture and assert per-file replacement only changes the intended file.
- An external write after an unsaved GUI edit must survive Ctrl+S; assert disk bytes and capture the visible conflict alert.
- Fixtures must have an isolated config/data namespace so prior CI sessions cannot make a false pass.

---

### Task 1: Publish baseline captures

**Files:** `docs/migration/evidence/{README.md,startup.jpg,folder.jpg,file.jpg}` and PR #1 body.

**Interface:** Three unedited JPEG frames from run `38720659614`, with SHA-256 and the run's exact source commit.

- [x] Decode hosted log frames without modifying pixels.
- [x] Verify images visually and hash each file.
- [x] Commit and link the captures with candidate/provenance wording in PR #1 (`8b50a0f`).

### Task 2: Multi-file tabs and session reopening

**Files:** Create `scripts/probe-editor-acceptance.ps1`; modify `.github/workflows/editor-candidate.yml`.

**Interface:** `probe-editor-acceptance.ps1 -Scenario Tabs` returns nonzero unless three fixture files receive distinct tab edits, close gracefully, and receive distinct second edits after reopening in the same isolated profile. It emits bounded tab and reopened-session screenshots.

- [x] Write the fixture, launch helpers, and three-file tab assertions (`34ebb07`).
- [x] Run the hosted workflow and inspect the assertion and screenshot evidence ([run 38724671470](https://github.com/Gerbzz/CodeStrike/actions/runs/38724671470)).
- [x] Resolve the observed CI window timeout with a 120-second bounded gate and rerun; no editor source failure was demonstrated (`75843fa`).
- [x] Record exact passed behavior in `docs/migration/ACCEPTANCE.md` and the screenshot provenance record (`2172f4f`).

### Task 3: Search and replacement

**Files:** Extend `scripts/probe-editor-acceptance.ps1`; modify pinned patch only if behavior is missing or broken.

**Interface:** `-Scenario Search` records a workspace-search result capture and verifies a per-file replace and Ctrl+S changes only the intended synthetic file. A reviewable workspace-wide replace is recorded as pending unless implemented and tested.

- [x] Add unique search fixture and search/result capture (`75843fa`).
- [x] Add per-file replace interaction and disk assertions (`c46266f`); hosted outcome pending.
- [ ] Run hosted workflow; fix any demonstrated source defect with regression coverage and rerun.
- [ ] Record scope and commit.

### Task 4: GUI external-change conflict

**Files:** Extend `scripts/probe-editor-acceptance.ps1`; edit `editor/patches/codestrike-lapce.patch` only for a demonstrated bug.

**Interface:** `-Scenario Conflict` edits one file without saving, writes different bytes externally, invokes GUI Save, asserts external bytes remain intact, and captures the GUI alert/editor state.

- [x] Add the disposable file interaction and disk assertion (`75843fa`).
- [x] Run hosted workflow; disk was preserved and visible alert captured in [run 38724671470](https://github.com/Gerbzz/CodeStrike/actions/runs/38724671470); no source fix needed.
- [x] Record the result in `docs/migration/ACCEPTANCE.md` and the screenshot provenance record (`2172f4f`).

### Task 5: Publish acceptance record

**Files:** Update `docs/migration/ACCEPTANCE.md`, `docs/migration/evidence/README.md`, and PR #1 body.

**Interface:** Each claimed pass links to a hosted run and image; every remaining limitation stays explicit.

- [ ] Review all screenshots and CI logs against assertions.
- [ ] Update docs, hashes, and draft PR; verify baseline and disk floor.
- [ ] Leave draft PR unmerged and report exact commit/run links.
