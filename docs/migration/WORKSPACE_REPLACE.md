# Checked workspace replacement candidate

Status: **draft implementation under Windows verification**. This is a
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
matches. The ignore walker honors `.gitignore` even for a folder outside a
Git repository. Symlinks and files outside the canonical workspace are
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
release. These limits keep the feature in draft status until native GUI
apply/undo and interruption cases have passed.
