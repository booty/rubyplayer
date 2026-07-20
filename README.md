# rubyplayer

A terminal (TUI) music player for retro game-music and tracker formats — chiptunes (NSF, GBS, HES, SPC, VGM, SAP, GYM, AY, KSS via [libgme](https://bitbucket.org/mpyne/game-music-emu/wiki/Home)) and tracker modules (MOD, XM, IT, S3M, and more via [libopenmpt](https://lib.openmpt.org/libopenmpt/)). Written in Ruby, with a small C shim ([miniaudio](https://miniaudio.docs/)) for audio output.

## Requirements

- Ruby 4.x (managed via [mise](https://mise.jdx.dev/); see `.ruby-version`)
- Homebrew: `libgme`, `libopenmpt`, `sox`, `ffmpeg`
- `bsdtar` (ships with macOS; fallback: `brew install libarchive`)
- Xcode command-line tools (`clang`) to build the native audio shim

## Setup

```sh
brew install libgme libopenmpt sox ffmpeg
mise install
bundle install
```

## Running

```sh
bin/rubyplayer [path ...]
```

`rake compile` builds the native audio shim (`lib/rubyplayer/native/librp_audio.dylib`) automatically as a prerequisite of `rake test`; `bin/rubyplayer` expects it to already exist, so run `rake compile` (or `rake test`) at least once after a fresh checkout.

Startup checks every supported runtime dependency before taking over the terminal. Missing Homebrew packages are reported together with one `brew install ...` command. If only the bundled audio shim is missing, run `bundle exec rake compile`.

Any paths given on the command line are scanned into the library on startup, in addition to any roots already remembered from a previous run.

Select **Focus** in the Library pane, then choose a noise recipe in Tracks and press Enter to play it indefinitely. Focus sounds use SoX, are not added to the queue or library history, and stop when normal playback begins.

### Navigation and views

- Press `/` to filter current Tracks view live across title, artist, album, composer, and path. Enter accepts filter; Escape restores previous filter. Each view remembers its filter, cursor, and scroll position.
- Tracks pane title shows current source or folder breadcrumb plus visible item count. Long breadcrumbs keep leaf name and count visible.
- Pane-edge scrollbar appears only when rows overflow viewport.
- Terminals narrower than 72 columns show one full-width pane; Tab switches panes. Wider terminals retain two-pane layout.
- Fixed smart views expose **Recently Added**, **Unrated**, **Missing**, **Failed to Scan**, and **Most Played** track lists.
- In **Missing**, press `Ctrl+X` to permanently purge currently filtered/visible tracks and their playback history after confirmation.
- Playback footer shows current track timing and queued next track. During Focus playback it identifies active recipe, infinite duration, paused queue, and next queued track.

## Testing

```sh
mise exec -- bundle exec rake test
```

## Architecture

rubyplayer is a **single process with a handful of long-lived threads**, coordinated through a small set of thread-safe primitives rather than a supervisor/actor framework:

- **Main thread** — runs the terminal UI loop (`UI::App#run`): reads keyboard input, drains events, renders a frame, repeats.
- **Scanner thread(s)** — walk the filesystem and diff against the database (cheap, never opens a music file).
- **Extractor pool** — a bounded pool of worker threads that open each discovered file through the appropriate backend to pull out metadata (title, duration, subtune count, ...). This is where real decoding work happens during a scan, and it parallelizes because every native call into libgme/libopenmpt is marked `blocking: true` in the FFI binding, which releases Ruby's GVL for the duration of the call.
- **Decoder thread** — owned by `PlaybackEngine`. Pulls the head of the play queue, opens it via a backend, decodes audio in a loop, and pumps PCM into the native ring buffer.
- **miniaudio's own callback thread** — native (C), drains the ring buffer at the audio device's pace. It never touches Ruby.

Threads talk to each other through:

- **`EventBus`** — a self-pipe-backed queue. Background threads *publish* events (`:track_started`, `:scan_complete`, ...); the main loop `select()`s on the bus's read end alongside stdin, so it can react to both keyboard input and background progress without polling.
- **A lock-free SPSC ring buffer** (in the C shim) — the only channel between the decoder thread and the audio callback. The decoder writes, the callback reads; no Ruby object crosses that boundary.
- **Small mutex-guarded state** inside `PlaybackEngine` and `Database` (SQLite access is serialized through a single writer mutex; WAL mode allows concurrent readers).

### Library model

Everything the app knows about your music lives in a single SQLite database (`~/.local/share/rubyplayer/library.sqlite3`): a `folders` table and a `tracks` table. A "folder" isn't necessarily a directory — a multi-subtune file (an NSF with 20 songs in it) is modeled as a **virtual folder** whose children are its individual tracks. This unifies "browse a directory" and "browse the subtunes of one file" into the same tree-walking code in `LibraryPane`/`Library#children_of`.

Deleting things is a **soft delete**: rows get a `missing` flag rather than being `DELETE`d, mirroring what the Scanner already does when a file disappears from disk. This sidesteps the lack of cascading foreign keys between `folders`/`tracks`/`playback_history`, and means a folder removed from the library reappears naturally if it's ever rescanned.

### Rendering

The TUI is a custom **double-buffered renderer** (`UI::Screen`), not a curses wrapper: every frame writes into a back buffer of styled cells, and `flush` diffs it against what was last drawn to emit the minimal ANSI escape sequences needed to reconcile the two. Cells support foreground/background color, bold, italic, underline, and dim text. There's no z-order — whatever draws last into a cell wins, which is how modal dialogs paint over the panes underneath at the end of `render`.

## File reference

### Entry point

| File | Purpose |
|---|---|
| `bin/rubyplayer` | Executable entry point. Boots `UI::App` with `ARGV` as initial scan paths; logs uncaught exceptions to `~/.local/share/rubyplayer/rubyplayer.log` before re-raising (the TUI owns the screen, so crashes can't just print to stdout). |

### Core (`lib/rubyplayer/`)

| File | Purpose |
|---|---|
| `rubyplayer.rb` | Top-level module: version constant and the `require_relative` list that loads the rest of the library in dependency order. |
| `config.rb` | Built-in defaults and `ConfigStore`: installs `examples/config.rb` when needed, transactionally loads executable `~/.config/rubyplayer/config.rb`, hot-reloads it, snapshots valid source to `config-previous.rb`, and restores that snapshot when primary source disappears. |
| `config_dsl.rb` | Validated configuration DSL and evaluator. Builds settings before activation, rejects unknown names with suggestions, and wraps syntax/runtime/validation failures as `ConfigError`. |
| `database.rb` | `Database`: owns the SQLite connection (WAL mode, foreign keys on), the schema (`folders`, `tracks`, `track_metadata`, `playback_history`), and a single-writer-mutex `write`/multi-reader `read` API. Backs up the existing DB file on open and rebuilds from scratch if the schema version doesn't match. |
| `track.rb` | `Track`: a keyword-init `Struct` mirroring a `tracks` row, with `Track.from_row` to build one from a SQLite result hash. This is the value object passed around the whole playback pipeline (queue, engine, UI panes). |
| `library.rb` | `Library`: the query/mutation layer over `Database` — upserting folders/tracks during a scan, reading folders plus source/smart views (`favorites`, `history`, Recently Added, Unrated, Missing, Failed to Scan, Most Played), rating tracks, soft-deleting folder subtrees, user-defined playlists (CRUD, position-ordered entries with move/remove, duplicate), and the track_metadata KV sidecar (full tag sets stored at scan, read on demand). No SQL lives outside this file (and `database.rb`'s schema). |
| `scanner.rb` | `Scanner`: phase 1 of a library scan. Walks a directory tree (or a single file), diffs what it finds against what the DB already knows (by mtime/size), and emits `WorkItem`s for anything new or changed — without opening a single music file. Archives are stat-diffed as a single unit (one mtime check covers every entry inside). Also marks anything that's vanished from disk as missing. |
| `extractor_pool.rb` | `ExtractorPool`: phase 2 of a scan. A bounded thread pool (size configurable, default = CPU core count) that opens each `WorkItem` through the right backend to extract metadata, expands multi-subtune files into virtual folders + child tracks, and flags anything undecodable rather than losing it. Archives are unpacked via `ArchiveCache` and their entries (including nested archives and multi-subtune files) scanned recursively. |
| `archive_cache.rb` | `ArchiveCache`: extracts `.zip`/`.7z`/`.rar` containers into a content-addressed on-disk cache (keyed by path+mtime+size) so the FFI backends — which can only read real files — can decode entries stored inside archives. Uses `bsdtar` (libarchive, bundled with macOS), which reads all three formats and refuses path-traversal entry names. `materialize` resolves a track's `(physical_path, archive_entry)` pair to a real extracted file, chaining through nested archives. The cache directory is safe to delete at any time. |
| `play_queue.rb` | `PlayQueue`: the in-memory playback queue (`Track` objects, not DB rows). Head of the list is "currently playing" when the engine is playing. Supports insert-now/front/end, positional or by-id removal, and bounded undo/redo. |
| `playback_engine.rb` | `PlaybackEngine`: owns the decoder thread, the queue, and the `AudioOutput` device for the process's lifetime. UI threads call its public methods (commands in); it publishes events out via `EventBus`. Handles play/pause/skip/seek, disliked-track auto-skip, and per-track playback-history recording once a track has played past a configurable percentage. |
| `audio_output.rb` | `AudioOutput`: thin FFI wrapper around the native shim (`RpAudio`) — init/start/stop the device, write float32 stereo frames into its ring buffer, query playback position, pause. One instance per process (the C side holds module-level state). |
| `event_bus.rb` | `EventBus`: thread-safe event queue with a self-pipe wakeup, so the main loop's `IO.select` can block on stdin *and* background events simultaneously instead of polling. |
| `level_tap.rb` | `LevelTap`: feeds the bottom-line EQ animation. Runs a Goertzel-algorithm frequency analysis over a short rolling window of recently-played audio at log-spaced band frequencies. `push` runs on the decoder thread, `levels` on the UI thread, guarded by a mutex. |
| `track_formatter.rb` | `TrackFormatter`: runs configured formatter lambdas against a track and helper context, then normalizes strings and conditional fragments into validated styled segments. |
| `keymap.rb` | `Keymap`: maps normalized key names to action symbols, merging Ruby-config overrides over sensible single-letter defaults. Matching is case-insensitive. Pane-local bindings shadow global bindings. |
| `theme.rb` | `Theme`: named color palettes for the TUI — a semantic role (`border`, `selection_bg`, `text_muted`, ...) mapped to either a named ANSI symbol or a `"#rrggbb"` truecolor string. `Theme::DEFAULT` reproduces the app's original hardcoded ANSI colors exactly; `Theme::THEMES` holds the selectable named palettes. Widgets receive the active theme per render call, not at construction time, so switching is instant. |

### Format backends (`lib/rubyplayer/backends/`)

| File | Purpose |
|---|---|
| `registry.rb` | `Backends::Registry`: maps file extensions to backend names (gme vs. openmpt) and lazily instantiates/caches the actual backend objects, so the extension-mapping logic can be tested without the native libraries installed. Also classifies archive containers (`.zip`/`.7z`/`.rar`), which are "supported" but have no backend of their own — the `ExtractorPool` unpacks them and dispatches each entry to its real backend. |
| `gme.rb` | `Backends::Gme`: FFI bindings to libgme, plus `Handle` (an open, playable track) and metadata extraction for chiptune formats. Converts libgme's 16-bit PCM output to the app's canonical float32 format. |
| `openmpt.rb` | `Backends::Openmpt`: FFI bindings to libopenmpt, plus `Handle` and metadata extraction for tracker module formats. libopenmpt renders float natively, so no format conversion is needed. |

### Terminal UI (`lib/rubyplayer/ui/`)

| File | Purpose |
|---|---|
| `app.rb` | `UI::App`: wires every other component together and owns the main loop — key dispatch, event handling, config hot-reload, and the top-level `render`. This is the natural place to look first to see how a keypress becomes an action and how state changes reach the screen. |
| `screen.rb` | `Screen`: the double-buffered renderer described above (`put`/`clear_back`/`flush`), plus truecolor and named ANSI color support. Has no knowledge of panes, tracks, or layout — purely a drawing primitive. |
| `library_pane.rb` | `LibraryPane`: left-hand source tree with queue/history/favorites/Focus, five smart views, and folder hierarchy. Owns folder breadcrumbs, selection, scrolling, and overflow indicator. |
| `tracks_pane.rb` | `TracksPane`: right-hand item list for every source. Owns live filtering, per-view cursor/scroll memory, dynamic titles/counts, grouping/sorting where valid, and overflow indicator. Queue remains flat and ordered; filtered removal resolves underlying track identity. |
| `bottom_lines.rb` | Three bottom renderers: `PlaybackLine` (normal/Focus context, next queue item, EQ bars), `StatusLine` (transient feedback), and `HotkeyLine` (context-sensitive bindings). |
| `key_decoder.rb` | `KeyDecoder`: turns raw bytes read from a raw-mode terminal into the normalized key-name strings `Keymap` understands (arrow-key escape sequences, Enter, Tab, Ctrl-combinations, etc). |

### Native audio (`ext/rp_audio/`)

| File | Purpose |
|---|---|
| `rp_audio.c` | A minimal playback shim over vendored miniaudio: owns a lock-free SPSC ring buffer of float32 interleaved stereo frames. The Ruby decoder thread is the producer (via `rp_write`, an FFI call with the GVL released); miniaudio's own native callback is the consumer and never touches Ruby. Compiled to `lib/rubyplayer/native/librp_audio.dylib` by `rake compile`. |
| `miniaudio.h` | Vendored single-header [miniaudio](https://miniaudio.docs/) library — the actual cross-platform audio device backend. Not modified. |

### Other directories

| Path | Purpose |
|---|---|
| `test/` | Minitest suite, one file per class above plus `test_helper.rb` (fixture path constant, requires). Run with `rake test`. |
| `fixtures/` | Real sample files in every supported format, used by the test suite and for manual verification. |
| `examples/config.rb` | Packaged executable-config starter. First run copies it to `~/.config/rubyplayer/config.rb`; settings remain commented so future built-in default changes still apply. |
| `docs/superpowers/` | Design spec and implementation plan produced while building this project. |
| `ideas.md` | Original freeform brainstorm this project's design was distilled from. |

## Configuration

User configuration is executable Ruby at `~/.config/rubyplayer/config.rb`.
On first run rubyplayer atomically copies packaged `examples/config.rb` there.
Starter includes common settings, maps, and formatter examples, but leaves them
commented so built-in defaults can evolve between releases.

> **Security:** `config.rb` is ordinary Ruby, not a sandbox. It runs with your
> user account's permissions. Only use configuration you wrote or reviewed.

Override settings through `RubyPlayer.configure`:

```ruby
RubyPlayer.configure do |config|
  config.ui.theme = "ocean_mist"
  config.ui.library_pane_percent = 30
  config.audio.sample_rate = "auto"
  config.scanner.thread_count = 0

  config.keymap.global["ctrl+p"] = :toggle_play
  config.keymap.tracks["j"] = :nav_down
  config.backends[".xyz"] = :ffmpeg
end
```

Normal Ruby variables, methods, conditionals, loops, and multiple
`RubyPlayer.configure` blocks work. Blocks apply in source order. Unknown
settings fail with a nearest-name suggestion; invalid values identify their
setting path.

### Reload and recovery

Rubyplayer checks `config.rb` once per second:

- Valid saves activate atomically and copy exact validated source to
  `~/.config/rubyplayer/config-previous.rb`.
- Missing primary config is restored from `config-previous.rb`. If both user
  files are absent, packaged example is installed again.
- Invalid hot reloads keep current in-memory config and open an exception modal.
  Fix and save again; successful reload closes it.
- Invalid startup config falls back to valid `config-previous.rb` and displays
  original error after UI opens.
- Startup exits only when primary config fails and previous config is missing or
  also fails.

Press Escape or Enter to dismiss error modal without changing active config.

To intentionally reset config, remove both `config.rb` and
`config-previous.rb`, then restart. Rubyplayer installs fresh packaged example.
These user files live under `~/.config`, outside repository, so repository
`.gitignore` entries are unnecessary.

Theme picker writes one clearly marked managed block at end of `config.rb`.
Rubyplayer replaces only that block; user code and comments remain untouched.

Hot reload immediately applies pane width, seek interval, theme, keymap, History
limit, star glyph, and track formatters. Settings used to construct audio,
scanner, database, archive, playback, status-line, or frame-loop objects require
restart.

### Setting reference

| Setting | Default | Meaning |
|---|---:|---|
| `config.ui.library_pane_percent` | `33` | Library width, integer `1..99`. |
| `config.ui.frame_fps` | `30` | Frame limit; positive integer. |
| `config.ui.status_message_seconds` | `5` | Status duration; positive integer. |
| `config.ui.seek_seconds` | `10` | Seek step; positive integer. |
| `config.ui.format_track_grouped` | callable | Grouped-row formatter. |
| `config.ui.format_track_ungrouped` | callable | Flat-row formatter. |
| `config.ui.theme` | `"default"` | Id from `Theme::ALL_IDS`. |
| `config.audio.sample_rate` | `"auto"` | Device-native or positive integer Hz. |
| `config.audio.ring_buffer_ms` | `500` | Audio buffer; positive integer ms. |
| `config.audio.decode_chunk_frames` | `4096` | Decode chunk; positive integer frames. |
| `config.scanner.thread_count` | `0` | Extractor workers; `0` uses CPU count. |
| `config.library.backup_retention` | `10` | SQLite backups retained. |
| `config.library.history_limit` | `100` | Tracks shown in History. |
| `config.library.history_min_percent` | `5` | Played threshold, `0..100`. |
| `config.library.history_min_seconds_unknown` | `30` | Threshold for unknown durations. |
| `config.library.undo_depth` | `10` | Queue undo/redo depth. |
| `config.library.archive_cache_dir` | `~/.cache/rubyplayer/archives` | Extracted archive cache. |
| `config.library.archive_tool` | `"bsdtar"` | Archive executable. |
| `config.eq.bands` | `16` | Analyzer band count. |
| `config.eq.fps` | `30` | Analyzer update rate. |
| `config.glyphs.dir` | folder glyph | Directory icon. |
| `config.glyphs.archive` | archive glyph | Archive icon. |
| `config.glyphs.playlist` | list glyph | Playlist icon. |
| `config.glyphs.multitrack` | chip glyph | Multi-subtune icon. |
| `config.glyphs.star` | `"★"` | Rating character. |
| `config.glyphs.missing` | warning glyph | Missing-track icon. |
| `config.glyphs.errored` | circle-x glyph | Failed-scan icon. |
| `config.glyphs.play` | play glyph | Playing icon. |
| `config.glyphs.pause` | pause glyph | Paused icon. |
| `config.glyphs.eq_chars` | `" ▁▂▃▄▅▆▇█"` | EQ levels, quiet to loud. |
| `config.glyphs.focus` | focus glyph | Focus view icon. |
| `config.keymap.global` | `{}` | Global key/action overrides. |
| `config.keymap.library` | `{}` | Library overrides; beat global bindings. |
| `config.keymap.tracks` | `{}` | Tracks overrides; beat global bindings. |
| `config.backends` | `{}` | Extension/backend overrides; dot optional. |

Map settings use bracket assignment:

```ruby
RubyPlayer.configure do |config|
  config.keymap.library["j"] = :nav_down
  config.keymap.library["k"] = :nav_up
  config.backends["vgm"] = :gme
end
```

## Track formatters

Formatters receive `(track, fmt)` and return a string, one helper fragment, or
nested arrays of either. `nil` and empty fragments disappear, making normal Ruby
conditionals safe inside `fmt.line`.

Available `track` fields:

`id`, `folder_id`, `physical_path`, `archive_entry`, `subtune_index`, `backend`,
`format`, `title`, `album`, `artist`, `composer`, `track_number`, `duration_ms`,
`rating`, `missing`, and `errored`.

Helpers:

- `fmt.text(value, **style)` — text unless value is nil/empty.
- `fmt.number(value, width: 2, **style)` — zero-padded number.
- `fmt.duration(milliseconds, **style)` — `M:SS`.
- `fmt.stars(rating, **style)` — configured star repeated by rating.
- `fmt.line(*parts, separator: " ")` — flatten, omit empty parts, join survivors.
- `fmt.album_artist` — dominant grouped-album artist, otherwise nil.

Style keys: `fg`, `bg`, `bold`, `italic`, `underline`, and `dim`. Colors accept:

- Theme roles: `:text`, `:text_muted`, `:primary`, `:accent`, `:warning`, etc.
- ANSI names: `:red`, `:yellow`, `:blue`, `:bright_cyan`, etc.
- True color: six-digit strings such as `"#ffaa00"`.

Selected-row foreground/background override formatter colors for contrast.
Bold, italic, underline, and dim remain active.

### Minimal preset

```ruby
config.ui.format_track_ungrouped = ->(track, fmt) {
  fmt.line(fmt.text(track.title, bold: true), fmt.text(track.artist, italic: true))
}
```

### Colorful preset

```ruby
config.ui.format_track_ungrouped = lambda do |track, fmt|
  fmt.line(
    fmt.text(track.album, fg: :accent),
    fmt.number(track.track_number, fg: :text_muted),
    fmt.text(track.title, fg: :primary, bold: true),
    fmt.text(track.artist, fg: "#7dd3fc", italic: true),
    fmt.stars(track.rating, fg: :yellow)
  )
end
```

### Compact preset

```ruby
config.ui.format_track_ungrouped = ->(track, fmt) {
  fmt.line(
    fmt.number(track.track_number),
    fmt.text(track.title, bold: true),
    fmt.duration(track.duration_ms, fg: :text_muted)
  )
}
```

### Metadata-heavy preset

```ruby
config.ui.format_track_ungrouped = lambda do |track, fmt|
  fmt.line(
    fmt.text("[#{track.format&.upcase}]", fg: :text_muted, dim: true),
    fmt.text(track.album, fg: :accent),
    fmt.number(track.track_number),
    fmt.text(track.title, bold: true),
    fmt.text("—"),
    fmt.text(track.artist, italic: true),
    fmt.text(track.composer ? "(#{track.composer})" : nil, fg: :text_muted),
    fmt.duration(track.duration_ms, fg: :text_muted),
    fmt.stars(track.rating, fg: :yellow)
  )
end
```

### Conditional grouped preset

```ruby
config.ui.format_track_grouped = lambda do |track, fmt|
  fmt.line(
    fmt.number(track.track_number, fg: :text_muted),
    fmt.text(track.title, bold: true),
    fmt.duration(track.duration_ms, fg: :text_muted),
    (fmt.text(track.artist, italic: true) unless track.artist == fmt.album_artist),
    (fmt.text("missing", fg: :error, bold: true) if track.missing == 1),
    (fmt.stars(track.rating, fg: :yellow) if track.rating)
  )
end
```
