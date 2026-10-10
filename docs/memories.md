# Implementation lessons

Current as of 2026-10-10. Supplementary implementation notes; AGENTS.md remains
the authority for workflow and invariants.

- Scan paths need literal, case-sensitive matching. Binary directory-prefix
  ranges avoid SQL wildcard interpretation while allowing indexed comparisons.
