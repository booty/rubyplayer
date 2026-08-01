# Agent guidance

## Response style

Respond terse like smart caveman. Technical substance stay. Fluff die.

- Drop articles, filler, pleasantries, hedging.
- Fragments OK. Technical terms exact. Code unchanged.
- Pattern: `[thing] [action] [reason]. [next step].`
- Switch: `/caveman lite|full|ultra|wenyan`.
- Stop: `stop caveman` or `normal mode`.
- Security warnings, irreversible actions, confused users: use clear normal prose.
- User-facing prose may be caveman-terse. Code, comments, commits, PRs, docs: normal English unless task says otherwise.

## Project

Ruby 4.x macOS TUI retro-game-music player. No framework. Double-buffered
terminal renderer. FFI: libgme, libopenmpt, ffmpeg. Native miniaudio shim.
SQLite library. Raw-TTY app; verify through tests, not headless launch.

Read `README.md` for user-facing architecture, configuration, and file map.
Read `docs/README.md` for documentation authority. This file is canonical
agent guidance: workflow, invariants, gotchas, refactor seams, testing.

Don't create git worktrees.

Work on git branch `main`

## Commands

```sh
mise exec -- bundle exec rake test                    # full suite
mise exec -- bundle exec ruby -Itest test/foo_test.rb # one test file
mise exec -- bundle exec rake compile                 # native audio shim
```

Ruby comes from mise. Plain `bundle exec` may select wrong Ruby.

## Performance Goals

- Idle (no music playing) CPU usage should be near-zero

## Workflow

- TDD: failing test first, minimal green change, full suite before commit.
- One commit per feature/fix.
- Comments explain why, not what. Comment surprising decisions at source.
- User-tunable values belong in `config.rb` `DEFAULTS`.
- Internal algorithm/timing values use named local/class constants, not config.
- Before commit: run full suite and relevant native compile.

## Architecture invariants

- Threads: main UI, scanner, extractor pool, PlaybackEngine decoder, native
  miniaudio callback. UI calls engine public API. Events return through
  `EventBus` self-pipe so `IO.select` waits on stdin and events.
- Scan has two sequential phases. `Scanner#reconcile` stats only; never opens
  files. `ExtractorPool` opens/decodes. Archive missing/restore logic depends
  on phase order.
- Renderer is last-writer-wins. Modals draw last in `App#render`. `Screen`
  stays pure drawing primitive; layout stays out.
- Themes pass per render (`theme:`); widgets do not store construction theme.
- Queue view stays flat, unsorted. Row index equals queue position. Sort/group
  prefs are shared; `TracksPane#show` must not reset them.
- Library scan soft-deletes only: `missing = 1`; never hard-delete scan rows.
  Only track metadata/playlists use hard deletion where defined.
- FFI calls use `blocking: true`; extractor pool needs GVL release.
- Archives: `physical_path` is on-disk archive; `archive_entry` is inner path,
  including nested chains. Scanner diffs archive folder rows, not track rows.
  Backends read real files; `ArchiveCache#materialize` resolves cache paths.
- Audio contract: little-endian float32, interleaved stereo. Use
  `AudioFormat::CHANNELS`, `BYTES_PER_FRAME`, and related constants.

## Gotchas

- GME: use `gme_info_t.length`; `play_length` fallback defaults to 150000ms.
  `length == -1` means unknown. NSF/HES may have `.m3u` sidecars; `gme.rb`
  loads titles and lengths.
- Metadata fixes do not rescan unchanged files. DB values live in
  `~/.local/share/rubyplayer/library.sqlite3`; delete DB for full rescan.
- `StringIO#string` returns live buffer. Capture `out.string.size` before writes.
- Keymap is case-insensitive. Pane-local bindings shadow global. Check
  `keymap.rb` before assigning keys; current collision-safe sort keys are
  `y`, `#`, `@`.
- `Database` rebuilds on schema-version mismatch after backup. Pre-1.0 schema
  changes: bump version; do not add migrations.
- Playback state key is `state[:track]`, not `state[:current]`.
- Config persistence uses separate managed blocks through `persist_managed` for
  `theme` and `art_mode`; each update preserves user code/comments. New
  persisted settings follow same per-setting managed-block pattern.
- Archives use macOS `bsdtar`; without `-P`, path-traversal entry names refuse.

## Refactor seams

- `DurationFormatter`: shared milliseconds-to-text formatter. Callers choose
  unknown fallback through `unknown:`.
- `Backends::MetadataHelper`: shared tag presence and normalized extension
  logic. Backend decoding stays backend-local.
- `AudioFormat`: canonical PCM constants. Do not duplicate frame arithmetic.
- `test/support/async_wait.rb`: shared async polling. Use it; avoid ad-hoc
  sleeps that create flaky tests.
- App specs split by concern in `app_*_test.rb`; shared setup lives in
  `TestSupport::AppTestSupport`. Do not grow `test/app_test.rb` catch-all.

## Testing

- Fixtures are real: vgm/nsf/gbs/spc/mod/xm/s3m/mp3 plus zip/7z/rar.
- Scanner tests may use empty fake files; scanner stats only.
- Engine tests use `null_backend: true`; no audio device.
- UI tests render into `Screen.new(out: StringIO.new, ...)`; inspect
  `screen.flush` or `@back` cells for fg/bg/bold/italic.
- Regression tests keep comments explaining original bug.

## Memories

- After a successful feature implementation (tests have passed) commit any lessons learned to memories to help future agent sessions. Look for duplication or contradiction with previous memories, updating/merging/removing older memories as needed.
