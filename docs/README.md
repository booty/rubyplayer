# Documentation source of truth

Use these files as normative guidance:

- `README.md` — user-facing architecture and configuration.
- `CLAUDE.md` — workflow, invariants, and gotchas.
- `AGENTS.md` — agent behavior.

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

Verify behavior with `mise exec -- bundle exec rake test`; rebuild native code
with `mise exec -- bundle exec rake compile`. Check relevant real files in
`fixtures/` and shared test setup/helpers in `test/test_helper.rb` and
`test/support/`.
