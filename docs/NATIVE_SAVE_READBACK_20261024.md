# Native startup save-readback readiness

Postmerge main `6ce7200ad87c82adc73c0d963b1213c44e5f375e` failed the file
smoke in [editor run40058782565](https://github.com/Gerbzz/CodeStrike/actions/runs/40058782565)
at03:39:10UTC. The full source save tests and later native scenarios passed;
contracts passed and independent language run40058782676 passed all3 fixtures.
This does not make the editor workflow green.

Artifact12546996527 retains `artifacts/lapce-native/file.jpg`: the actual
`main.rs` editor shows the full inserted `codestrike_ci_saved` marker and a dirty
tab. The foreground handle458836 equals the expected editor handle. The console
retains the original disk source, `fn main() { println!("CodeStrike fixture"); }`
with its terminal newline. Thus typing reached the correct editor, but the
original two-second readback did not observe a completed save. No modal is
visible. The existing evidence does not distinguish a delayed save from a
missed save dispatch, and no application save fix is claimed.

The narrow probe change keeps the single native Ctrl+S, unchanged marker
predicate and same timeout failure. It polls only the saved source for up to
10seconds, matching the existing asynchronous native acceptance observation
budget, rather than making one fixed two-second snapshot. It never resends input
or writes fixture content; the final read, elapsed time and count are retained,
and the existing genuine capture still precedes any timeout throw.

Regressions cover delayed success, never-written timeout, wrong content and
no extra input/file mutation. Cross-platform contracts preserve the one native
save and original predicate/throw. Hosted results must validate the exact
candidate; a pass alone is not proof of the previous failure's internal cause.
