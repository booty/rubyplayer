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

The TUI is a custom **double-buffered renderer** (`UI::Screen`), not a curses wrapper: every frame writes into a back buffer of `(char, fg, bg, bold)` cells, and `flush` diffs it against what was last drawn to emit the minimal ANSI escape sequences needed to reconcile the two. There's no z-order — whatever draws last into a cell wins, which is how modal dialogs (e.g. the delete-confirmation prompt) simply paint over the panes underneath at the end of `render`.

## File reference

### Entry point

| File | Purpose |
|---|---|
| `bin/rubyplayer` | Executable entry point. Boots `UI::App` with `ARGV` as initial scan paths; logs uncaught exceptions to `~/.local/share/rubyplayer/rubyplayer.log` before re-raising (the TUI owns the screen, so crashes can't just print to stdout). |

### Core (`lib/rubyplayer/`)

| File | Purpose |
|---|---|
| `rubyplayer.rb` | Top-level module: version constant and the `require_relative` list that loads the rest of the library in dependency order. |
| `config.rb` | `ConfigStore`: loads `~/.config/rubyplayer/config.toml`, deep-merges it over `DEFAULTS`, and supports hot-reload (`reload_if_changed`, polled by the main loop) when the file's mtime changes. Invalid TOML never crashes the app — defaults win. Also defines `RubyPlayer.config_path`, `data_dir`, and `logger`. |
| `database.rb` | `Database`: owns the SQLite connection (WAL mode, foreign keys on), the schema (`folders`, `tracks`, `track_metadata`, `playback_history`), and a single-writer-mutex `write`/multi-reader `read` API. Backs up the existing DB file on open and rebuilds from scratch if the schema version doesn't match. |
| `track.rb` | `Track`: a keyword-init `Struct` mirroring a `tracks` row, with `Track.from_row` to build one from a SQLite result hash. This is the value object passed around the whole playback pipeline (queue, engine, UI panes). |
| `library.rb` | `Library`: the query/mutation layer over `Database` — upserting folders/tracks during a scan, reading folders plus source/smart views (`favorites`, `history`, Recently Added, Unrated, Missing, Failed to Scan, Most Played), rating tracks, and soft-deleting folder subtrees. No SQL lives outside this file (and `database.rb`'s schema). |
| `scanner.rb` | `Scanner`: phase 1 of a library scan. Walks a directory tree (or a single file), diffs what it finds against what the DB already knows (by mtime/size), and emits `WorkItem`s for anything new or changed — without opening a single music file. Archives are stat-diffed as a single unit (one mtime check covers every entry inside). Also marks anything that's vanished from disk as missing. |
| `extractor_pool.rb` | `ExtractorPool`: phase 2 of a scan. A bounded thread pool (size configurable, default = CPU core count) that opens each `WorkItem` through the right backend to extract metadata, expands multi-subtune files into virtual folders + child tracks, and flags anything undecodable rather than losing it. Archives are unpacked via `ArchiveCache` and their entries (including nested archives and multi-subtune files) scanned recursively. |
| `archive_cache.rb` | `ArchiveCache`: extracts `.zip`/`.7z`/`.rar` containers into a content-addressed on-disk cache (keyed by path+mtime+size) so the FFI backends — which can only read real files — can decode entries stored inside archives. Uses `bsdtar` (libarchive, bundled with macOS), which reads all three formats and refuses path-traversal entry names. `materialize` resolves a track's `(physical_path, archive_entry)` pair to a real extracted file, chaining through nested archives. The cache directory is safe to delete at any time. |
| `play_queue.rb` | `PlayQueue`: the in-memory playback queue (`Track` objects, not DB rows). Head of the list is "currently playing" when the engine is playing. Supports insert-now/front/end, positional or by-id removal, and bounded undo/redo. |
| `playback_engine.rb` | `PlaybackEngine`: owns the decoder thread, the queue, and the `AudioOutput` device for the process's lifetime. UI threads call its public methods (commands in); it publishes events out via `EventBus`. Handles play/pause/skip/seek, disliked-track auto-skip, and per-track playback-history recording once a track has played past a configurable percentage. |
| `audio_output.rb` | `AudioOutput`: thin FFI wrapper around the native shim (`RpAudio`) — init/start/stop the device, write float32 stereo frames into its ring buffer, query playback position, pause. One instance per process (the C side holds module-level state). |
| `event_bus.rb` | `EventBus`: thread-safe event queue with a self-pipe wakeup, so the main loop's `IO.select` can block on stdin *and* background events simultaneously instead of polling. |
| `level_tap.rb` | `LevelTap`: feeds the bottom-line EQ animation. Runs a Goertzel-algorithm frequency analysis over a short rolling window of recently-played audio at log-spaced band frequencies. `push` runs on the decoder thread, `levels` on the UI thread, guarded by a mutex. |
| `template.rb` | `Template`: parses a config-supplied format string like `"{track_number} {title} {duration}"` once, then renders it per track. Field substitution is a fixed whitelist — arbitrary `{...}` content can never execute code, it just renders empty. |
| `keymap.rb` | `Keymap`: maps normalized key names to action symbols, merging user TOML config over sensible single-letter defaults. Matching is case-insensitive. Supports per-pane overrides (a pane-local binding shadows the global one for that key) via `action_for(key, pane:)`. |
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
| `docs/superpowers/` | Design spec and implementation plan produced while building this project. |
| `ideas.md` | Original freeform brainstorm this project's design was distilled from. |

## Configuration

On first run, rubyplayer creates no config file — it runs entirely on the defaults baked into `RubyPlayer::DEFAULTS` (`lib/rubyplayer/config.rb`). To customize, create `~/.config/rubyplayer/config.toml` with only the keys you want to override; anything you don't specify keeps its default. Config changes are picked up automatically while the app is running (checked once a second).

Keys of particular interest:

- `[audio] sample_rate` — `"auto"` (device-native) or a fixed integer Hz.
- `[scanner] thread_count` — `0` means "one per CPU core".
- `[keymap.global]`, `[keymap.library]`, `[keymap.tracks]` — override or add keybindings; pane-scoped tables take priority over `global` for the same key.
- `[ui] format_string_grouped` / `format_string_ungrouped` — track row templates (see `template.rb` for the available `{field}` tokens).
- `[ui] theme` — active color scheme id (see `theme.rb` for the full list). Normally set via the in-app theme picker (`T`), which persists your choice back into this key; hand-editing it also works and is picked up on the next hot-reload.
