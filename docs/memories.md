# Implementation lessons

Current as of 2026-10-10. Supplementary implementation notes; AGENTS.md remains
the authority for workflow and invariants.

- Scan paths need literal, case-sensitive matching. Binary directory-prefix
  ranges avoid SQL wildcard interpretation while allowing indexed comparisons.
- SQLite backups must include committed WAL pages. Use the backup API and
  publish only completed snapshots; copying the main file alone loses data.
