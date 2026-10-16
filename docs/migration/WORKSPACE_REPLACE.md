# Checked workspace replacement candidate

Status: **draft implementation with one passing Windows GUI path**. This is a
separate workflow inside the search panel; the existing per-file Replace All
remains available. Search results alone never write files.

1. Enter a search expression and replacement, then open **Workspace replace**
   and choose **Preview changes**. The preview lists each affected relative
   path, match count, line and UTF-8 byte column, matched text, replacement
   expansion, and source-line context. It also reports skipped unsupported,
   read-only and oversized files. Editing the query, replacement or matching
   flags invalidates the preview.
2. **Apply preview** checks every planned path, permissions and full original
   bytes again. It refuses dirty open buffers. On Windows, each file swap
   excludes other write handles, retains a uniquely named hard-link backup of
   the original, and installs the new bytes only at an absent pathname. A
   later externally changed file stops the batch rather than being replaced.
   Already-applied files remain listed for checked undo if a later file fails.
3. **Checked Undo** first requires every affected file still to contain its
   exact applied bytes and every recovery backup still to contain its exact
   original bytes. If any differ, it refuses the whole undo without
   overwriting the newer content. Successful undo restores the originals.
   Open buffers receive a proxy snapshot refresh so a later normal save uses
   the new disk version.

The operation is bounded to local Windows folders: at most 2 MiB per scanned
file, 20 MiB of original plus replacement bytes, 200 changed files, and 500
matches. Search and replacement inputs are capped at 4096 bytes each, and
individual matches at 1024 bytes. The ignore walker honors `.gitignore` even
for a folder outside a Git repository. Symlinks and files outside the
canonical workspace are
excluded; invalid UTF-8, UTF-16/NUL-containing and read-only files are not
rewritten. Literal and regex search use Unicode-aware matching; regex
replacement supports captures. Zero-length and multiline matches are
refused.

The batch is **not atomic across files**. A conflict or I/O failure after
earlier files succeed leaves a visible partial result and recovery backups.
Undo is available within the current editor session; the backups remain
after exit for manual recovery. No automatic cross-session restore or cleanup
is implemented. An external process that atomically swaps a pathname during
the short per-file operation is still a concurrency risk to evaluate before
release. [Hosted Windows run 38757901744](https://github.com/Gerbzz/CodeStrike/actions/runs/38757901744)
passed the native GUI preview, changed-since-preview refusal, two-file Apply,
newer-edit Undo refusal, and checked two-file Undo. The probe compared full
file bytes before and after each operation, including a UTF-8 BOM/CRLF file,
and confirmed ignored, read-only, and unsupported files were not changed.
The matching engine also passed four focused Rust tests for literal and regex
replacement, captures, Unicode word behavior, BOM retention, and conflict
checks. Interrupted operations, process crashes, cross-session recovery,
manual backup cleanup, and concurrent atomic pathname replacement remain
unverified. The backup files remain visible after a successful Undo.
