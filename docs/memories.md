# Implementation lessons

Current as of 2026-10-10. Supplementary implementation notes; AGENTS.md remains
the authority for workflow and invariants.

- Scan paths need literal, case-sensitive matching. Binary directory-prefix
  ranges avoid SQL wildcard interpretation while allowing indexed comparisons.
- SQLite backups must include committed WAL pages. Use the backup API and
  publish only completed snapshots; copying the main file alone loses data.
- Empty extraction work can follow a deletion-only reconciliation. Always
  recompute folder counts and publish scan completion, even with zero workers.
- Decoder command waits can block indefinitely when idle or paused. Every
  transition requiring work arrives through the command queue.
- Frame state needs only a queue entry, not a queue snapshot. Cache Queued's
  duration summary alongside its upcoming snapshot and refresh both together.
- Screen cells are replaced, not mutated. Sharing frozen BLANK across slots
  reduces a 120x40 clear from 4,842 allocations to 42 without changing diffs.
- GME metadata iteration owns one metadata-only handle per file and yields
  metadata, subtune index, and total count. Keep handles worker-local and use
  the existing ensure-based cleanup; sibling M3U metadata must remain intact.
