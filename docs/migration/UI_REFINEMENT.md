# CodeStrike candidate UI refinement

Status: **draft Lapce candidate**, with the original CodeStrike launcher still
available and unchanged. This pass uses the installed Impeccable design guidance
to refine a real editor workflow rather than adding decorative chrome. The
approved CodeStrike mark remains on startup and About; the working window is
reserved for files, tabs, search, and tools.

## Design decision

The candidate already has Lapce's workspace explorer, editor tabs, search,
terminal, and language-server wiring. The workspace replacement panel
was a weak point at an 800 x 600 Windows window: its disclosure and three
actions were clickable labels, its preview was limited to 90 px, and its status
used the dim text color. This pass keeps the existing checked replacement
engine and changes the surface around it:

- The disclosure and actions use Floem buttons with visible focus styling.
  Their keyboard activation still needs a native GUI check. Apply is disabled
  until a nonempty preview exists;
  Preview is unavailable while a prior application awaits Undo, and Undo is
  unavailable without an applied transaction.
- Actions share a row in the bottom panel and wrap when docked in a narrower
  side panel. The preview uses remaining panel height, with distinct file
  headers and indented match rows. Preview row keys include their content, so
  a second preview with the same match count refreshes changed text as
  [Floem's `dyn_stack` key contract](https://lapce.dev/floem/floem/views/fn.dyn_stack.html)
  requires. The empty state explains where results will appear.
- Status copy uses the normal foreground color. In the pinned Lapce dark
  theme, `#ABB2BF` on the panel's `#21252B` is about **7.22:1** contrast;
  disabled text remains visibly inactive.

## Native Windows evidence

[Hosted run 38988607403](https://github.com/Gerbzz/CodeStrike/actions/runs/38988607403)
compiled remote draft commit `595d560de29004ef8384b92e85c41f4dfcde3fb6`
and passed startup, three-tab reopen, and workspace replacement GUI checks.
The replacement probe opened an actual local fixture folder, previewed two
matches without writing, refused Apply after a second file changed externally,
then applied two replacements and restored exact original bytes with checked
Undo. Ignored, read-only, and unsupported files stayed unchanged. The log
marker is
`CODESTRIKE_ACCEPTANCE_WORKSPACE_REPLACE=preview-conflict-apply-undo-passed`.

A later keyboard probe found that transferring the global workbench focus
while pressing Tab or Enter also inserted a newline into the open file. That
left the file dirty and correctly blocked Apply. A follow-up kept focus in
the Search panel but shifted it to the query field and produced zero matches.
The experimental key handler and probe were removed from this draft; the
previously passing button-driven GUI path was restored. The first correction's hosted compile
[run 38991061607](https://github.com/Gerbzz/CodeStrike/actions/runs/38991061607)
found two zero-context patch hunks shifted by that removal; they were
reanchored before the
[final failed keyboard run 38991868364](https://github.com/Gerbzz/CodeStrike/actions/runs/38991868364).
Keyboard activation needs a deliberate focus design and passing native GUI run.

The [preview](../../assets/screenshots/codestrike-design-replace-preview-app.png)
and [conflict](../../assets/screenshots/codestrike-design-apply-conflict-app.png)
images are exact top-left 750 x 563 pixel app-window crops of the run's
`workspace_replace_preview` and `workspace_replace_apply_conflict` 960 x 720
JPEG log frames. They were saved as PNG without resizing, compositing, or
retouching. SHA-256: preview
`64174e8261d3ee64bf438f68d5484ec48fd468ebf089439a8e880c1d8544bb52`;
conflict
`58d8ada53bc9d69ddb6224855e82f60a767e7134d36bf283bdb0faa2b193aa58`.

## Remaining design and release work

The long match row still truncates context in a narrow panel. Conflict text
shows a raw long Windows path, and recovery backup files remain visible in the
explorer. These need a deliberate reviewable details view and clearer recovery
copy before this feels release ready. Keyboard activation, visible focus at
200% scaling, and high contrast themes also
remain unverified. The broader acceptance matrix still includes local Rust
diagnostics, clean-machine packaging, session/settings migration, and license
notices. Keep the candidate draft until those checks and an independent review
are complete.
