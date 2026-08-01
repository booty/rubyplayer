# CLAUDE.md

Guidance for Claude Code sessions working in this repo. `README.md` has the
full architecture overview and per-file reference — read it first. This file
holds what the README doesn't: workflow, gotchas, and hard-won learnings.

## What this is

A TUI retro-game-music player for macOS (Ruby 4.x, no framework). Custom
double-buffered terminal renderer, FFI bindings to libgme/libopenmpt/ffmpeg,
miniaudio native shim, SQLite library. Interactive raw-TTY app — it cannot be
run headlessly; verify behavior through the test suite, not by launching it.

## Commands

```sh
mise exec -- bundle exec rake test      # full suite (~2s). Always run before commit.
mise exec -- bundle exec ruby -Itest test/foo_test.rb   # one file
mise exec -- bundle exec rake compile   # rebuild ext/rp_audio native shim
```

Ruby comes from mise (4.0.1). Plain `bundle exec` may pick the wrong Ruby —
always go through `mise exec`.

## Workflow expectations

- **TDD, strictly.** Failing test first, watch it fail, minimal code to green,
  full suite before commit. One commit per feature/fix.
- **Comments explain why, not what.** Surprising decisions get an inline
  comment at the decision site (see any file — the codebase is consistent
  about this).
- **Magic values:** user-tunable settings belong in `DEFAULTS` in `config.rb`
  with a sensible default. Internal algorithm and timing constants belong as
  clearly named local/class constants near their use; do not force them into
  user configuration.
- Prose to the user may be caveman-terse (plugin-driven); code, comments,
  commit messages, and this kind of doc are always normal English.

## Architecture invariants (don't break these)

- **Threads:** main UI loop + scanner thread + extractor pool + decoder thread
  (PlaybackEngine) + miniaudio's native callback. UI threads talk to the
  engine via its public methods; events flow back through `EventBus`
  (self-pipe wakeup so `IO.select` blocks on stdin *and* events).
- **Scan is two sequential phases.** Phase 1 (`Scanner#reconcile`) only stats
  files — never opens them. Phase 2 (`ExtractorPool`) opens/decodes. Several
  correctness arguments (archive missing/restore dance) depend on phase 1
  finishing before phase 2 starts.
- **Renderer is last-writer-wins.** No z-order; modals work because they draw
  last in `App#render`. `Screen` is a pure drawing primitive — keep layout
  knowledge out of it.
- **Themes are passed per render call** (`theme:` kwarg), never stored in
  widgets at construction. That's what makes live theme preview instant.
- **Queue view renders flat and unsorted, always.** Row index == queue
  position is load-bearing (`remove_from_queue` uses it). Sort/group flags are
  shared user prefs across views — never reset them in `TracksPane#show`.
- **Soft delete only.** `missing = 1`, never hard DELETE — no cascading FKs
  beyond track_metadata, and rescans naturally restore rows.
- **FFI calls use `blocking: true`** so they release the GVL — that's why the
  extractor pool gets real parallelism.
- **Archives:** track rows keep `physical_path` = the archive file on disk and
  the inner path in `archive_entry` (nested chains like `a.zip/b.vgm`), so one
  stat diff covers the whole subtree. Scanner diffs archives against their
  *folder* row, not track rows (an archive of only unsupported formats has
  zero tracks and must not re-extract forever). Backends only read real files
  — `ArchiveCache#materialize` resolves to the extracted cache file first.

## Gotchas that have actually bitten

- **GME durations:** `gme_info_t.play_length` is a fallback that defaults to
  150000ms (2:30) — use `length` (-1 = unknown → nil). NSF/HES rips often ship
  a `.m3u` sidecar with real per-track lengths/titles; `gme.rb` loads it.
- **Stale DB after metadata fixes:** already-scanned values are baked into
  `~/.local/share/rubyplayer/library.sqlite3`. Unchanged mtime/size = no
  rescan. Delete the DB file to force a full rescan.
- **`StringIO#string` returns the live internal buffer.** Capturing it, then
  measuring `.size` after more writes gives wrong offsets. Capture
  `before_len = out.string.size` (an Integer) *before* mutating.
- **Keymap is case-insensitive**, and pane-local bindings shadow global ones.
  Claimed keys collide easily — that's why sort_title is `y` (global `t` =
  theme picker) and sort_number/sort_artist are `#`/`@` (global `n`/`a`
  taken). Check `keymap.rb` defaults before assigning a new key.
- **`Database` rebuilds from scratch on schema-version mismatch** (after
  backing up). Schema changes are cheap pre-1.0 — bump the version rather
  than writing migrations.
- **PlaybackEngine `state[:track]`**, not `state[:current]` — easy test typo.
- **No TOML writer dependency.** `ConfigStore#persist_theme` and
  `#persist_art_mode` persist settings through separate managed blocks via
  `persist_managed`. Each update replaces only its setting's block, preserving
  user code/comments and allowing theme and art-mode blocks to coexist. Future
  persisted settings must use the same per-setting managed-block pattern.
- **bsdtar over homebrew tools** for archives: ships with macOS, reads
  zip/7z/rar, and without `-P` refuses path-traversal entry names.

## Current refactor seams

- **`DurationFormatter`:** shared duration display formatter. Use it instead
  of duplicating milliseconds-to-text conversions; callers choose unknown
  fallback text with `unknown:`.
- **`Backends::MetadataHelper`:** shared backend metadata normalization.
  Use `presence` for optional tags and `format_extension` for normalized file
  formats; keep backend-specific decoding in each backend.
- **`AudioFormat`:** canonical PCM contract: little-endian float32,
  interleaved stereo. Backends and focus player produce it; audio output and
  native shim consume it. Use `CHANNELS`, `BYTES_PER_FRAME`, and related
  constants instead of duplicating frame math.
- **Shared async test helper:** `test/support/async_wait.rb` is included from
  `test/test_helper.rb`. Use it for polling async state; do not add ad-hoc
  sleeps that make tests flaky.
- **Split `App` specs:** keep behavior tests in focused `app_*_test.rb` files
  and reuse `TestSupport::AppTestSupport`; do not grow `test/app_test.rb` into
  another catch-all.

## Testing conventions

- Real fixtures in `fixtures/` (vgm/nsf/gbs/spc/mod/xm/s3m/mp3 + zip/7z/rar);
  tests decode them for real. Scanner tests fake with empty files (it only
  stats). Engine tests use `null_backend: true` audio (no device).
- UI assertions: render into `Screen.new(out: StringIO.new, ...)`, then either
  check `screen.flush` output or inspect the back buffer
  (`screen.instance_variable_get(:@back)`) for per-cell fg/bg/bold/italic.
- Regression tests carry a comment explaining the original bug — keep doing
  that.
