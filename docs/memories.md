# Implementation lessons

Current as of 2026-10-11. Supplementary implementation notes; AGENTS.md remains
the authority for workflow and invariants.

- Scan paths need literal, case-sensitive matching. Binary directory-prefix
  ranges avoid SQL wildcard interpretation while allowing indexed comparisons.
- SQLite backups must include committed WAL pages. Use the backup API and
  publish only completed snapshots; copying the main file alone loses data.
- Empty extraction work can follow a deletion-only reconciliation. Always
  recompute folder counts and publish scan completion, even with zero workers.
- Decoder command waits can block indefinitely when idle or paused. Every
  transition requiring work arrives through the command queue.
- Previous-track navigation uses decoder-owned session history, separate from
  the library's minimum-listening-threshold history. Restart seeks to zero;
  going back restores the queue head without creating a manual undo snapshot.
  Retain the last successful start across idle/error transitions; library
  deletion must clear navigation history after any queued current-track skip.
- Frame state needs only a queue entry, not a queue snapshot. Cache Queued's
  duration summary alongside its upcoming snapshot and refresh both together.
- Screen cells are replaced, not mutated. Sharing frozen BLANK across slots
  reduces a 120x40 clear from 4,842 allocations to 42 without changing diffs.
- Footer hints use effective pane bindings and reserve help before fitting
  whole hints. Derive pane, artwork, status, and input geometry from the same
  command-row count; test styled cells to distinguish bold keys from dim text.
- GME metadata iteration owns one metadata-only handle per file and yields
  metadata, subtune index, and total count. Keep handles worker-local and use
  the existing ensure-based cleanup; sibling M3U metadata must remain intact.
  Gate iteration on Registry's multitrack classification so custom backend
  overrides do not create virtual folders the scanner cannot preserve.
- LevelTap needs only the final window of a large PCM chunk. Short chunks must
  retain preceding samples; Goertzel coefficients depend only on construction.
- PlaylistModal snapshots lists on open and caches rows/labels until filtering
  changes. It returns intents to App; database mutations and pane refreshes
  stay in App. Render calls must not query the library.
