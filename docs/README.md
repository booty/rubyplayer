# Documentation source of truth

Use these files as normative guidance:

- `README.md` — user-facing architecture and configuration.
- `AGENTS.md` — canonical agent guidance: workflow, invariants, gotchas,
  refactor seams, and testing. `CLAUDE.md` only imports it.

Current supplementary implementation lessons live in [`memories.md`](memories.md).
They record tested decisions without replacing the guidance above.

Current visual explainers describe the implementation (the component map was
reviewed 2026-11-07, the playback and scan sequences 2026-10-10):

- [Component map](explainers/components.md)
- [Playback sequence](explainers/playback.md)
- [Library scan sequence](explainers/scanning.md)

Their Mermaid diagrams render on GitHub and in Markdown viewers with Mermaid
support. Source links below each diagram provide entry points for deeper reading.

These files are historical design records:

- `docs/ideas.md`
- `docs/playlists-planning.md`
- `docs/All Songs Views - Prelim.md`
- `docs/superpowers/plans/`
- `docs/superpowers/specs/`

When any historical design record drifts from implementation, tests, or current
guidance, implementation and tests win.

Future docs should state whether they are `current` or `superseded`, with a
date and a short replacement link when applicable. Do not edit historical
files to make them current; add or update a current index or document instead.

Verify behavior with `mise exec -- bundle exec rake test` (or the faster
`rake test:parallel` while iterating); rebuild native code
with `mise exec -- bundle exec rake compile`. Check relevant real files in
`fixtures/` and shared test setup/helpers in `test/test_helper.rb` and
`test/support/`.
