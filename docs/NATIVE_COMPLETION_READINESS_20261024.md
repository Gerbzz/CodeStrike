# Native completion acceptance: readiness race investigation

The post-merge main run [40053969310](https://github.com/Gerbzz/CodeStrike/actions/runs/40053969310)
failed fixture 1's exact UTF-8 saved-completion assertion; fixtures 2 and 3 passed,
as did unavailable-server/source-integrity acceptance. Artifact `12544234412`
contains the genuine failed `attempt-1/completion.jpg`. It shows no completion
popup, `::Re;` in the editor, and compiler_builtins indexing still at 11/21.

The reported failed saved-source SHA-256 was
`7641ddd6c4946167c1d792cff5afe3565f001a65e5b5b8bd726126c555ac8cfd`.
That is exactly the fixture's original UTF-8 source with `::Re;` changed to
`::Re\n;`: pressing Enter before a completion row exists inserted a newline,
and that source was saved. This is different from the previously investigated
stock-analyzer diagnostic failure and historical startup file-smoke mismatch.
The failed attempt did not retain its raw trace: the old probe wrote it only
after the saved-byte assertion. We do not claim an unavailable trace proves
any other ordering or that all possible native failures have been repaired.

## Narrow repair under validation

- Replace fixed 45-second startup and 8-second completion sleeps with bounded,
  observable readiness. Require actual E0308 publication before the one native
  completion request, then a fresh native selected-Read row layout observation
  before the one Enter action. A server response alone never authorizes Enter.
- Native observation is a separate post-donor source overlay. It only reads
  completion state in the existing row's layout callback and emits opt-in debug
  fields: exact selected item label, current request/input IDs, row and actual
  positive finite dimensions. Inactive, stale-request, unselected and zero-size
  rows cannot emit the readiness marker. It does not set state, select a result,
  inject text, change layout, or gate or schedule application behavior.
- No existing completion accessibility surface or layout log was found in the
  pinned Lapce application. Pixel heuristics would couple readiness to colors,
  font metrics and scaling. The explicit observational callback avoids those
  assumptions. Layout is not a claim about compositor presentation: the probe
  still captures genuine pixels and must perform native Enter/save and compare
  every original expected UTF-8 byte.
- Stream capture is asynchronous, bounded to 16 MiB of characters, rejects
  overflow, preserves raw ANSI logs, and ignores earlier markers at the
  pre-request boundary. Finalization preserves source bytes and trace on failure
  too, with a best-effort genuine window capture if readiness times out. Each
  cleanup/evidence step is independent: errors cannot mask an original failure,
  while any evidence failure on an otherwise successful path still fails.
- All three fresh-GUID native fixtures remain mandatory, using one compiled
  binary. Existing E0308, exact UTF-8, unavailable-server and source-integrity
  gates are unchanged. This is not retry-until-pass or a fixture prebuild.

## Regression evidence

Four tests in the actual production observation module reject response-without-
layout, inactive/stale/unselected rows and invalid dimensions, accepting only a
current selected laid-out row. The local source harness failed before the helper
was added and passed all four after it. The hosted native workflow also runs
these production-source tests inside `lapce-app`.

Seven Windows capture checks exercise the probe's exact C# implementation:
response-only and wrong-label rejection, ANSI parsing, stale/fresh boundary,
raw-trace preservation and overflow rejection. Four finalization checks cover
original-error preservation, independent evidence, success-path loss rejection
and clean finalization. Three cross-platform contracts
preserve action ordering, failure evidence and mandatory native workflow wiring;
two fail against the previous probe and all three pass the candidate. These are
regressions, not replacements for actual native acceptance. Hosted results must
be reviewed at the exact published candidate head before calling this validated.
