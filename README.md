# rubyplayer

A terminal (TUI) music player for retro game-music and tracker formats — chiptunes (NSF, GBS, HES, SPC, VGM, SAP, GYM, AY, KSS via [libgme](https://bitbucket.org/mpyne/game-music-emu/wiki/Home)), tracker modules (MOD, XM, IT, S3M, and more via [libopenmpt](https://lib.openmpt.org/libopenmpt/)), and ordinary audio files (MP3, FLAC, AAC/M4A, Ogg, Opus, WAV, and more via FFmpeg). Written in Ruby, with a small C shim ([miniaudio](https://miniaudio.docs/)) for audio output.

<img width="1394" height="855" alt="image" src="https://github.com/user-attachments/assets/443610ad-c9ef-493d-ab7b-eb17f1d37645" />

Many popular chiptune formats support a live look into what the various sound channels are doing. Here's "The Shinobi" from *Revenge of Shinobi* / *The Super Shinobi* (Yuzo Koshiro) showing us what all of the Genesis' sound channels are doing. We can even see part of Yuzo's secret sauce here -- the seldom-used PSG channels are helping out the FM channels.

<img width="1415" height="908" alt="image" src="https://github.com/user-attachments/assets/a6339d61-343b-4cfc-b3a6-d7e9f1d17dc4" />


## Requirements

- Ruby 4.x (managed via [mise](https://mise.jdx.dev/); see `.ruby-version`)
- Homebrew: `libgme`, `libopenmpt`, `sox`, `ffmpeg`
- `bsdtar` (ships with macOS; fallback: `brew install libarchive`)
- Xcode command-line tools (`clang`) to build the native audio shim

## Setup

```sh
brew install libgme libopenmpt sox ffmpeg
mise install
mise exec -- bundle install
```

## Running

Install commands that work from any directory with YJIT enabled:

```sh
bin/install
rubyplayer [path ...]
rp [path ...]
```

The installer creates `~/.local/bin/rubyplayer` and an `rp` alias. If that
directory is absent from `PATH`, it prints the line to add to your shell
configuration (usually `~/.zshrc`). Use `bin/install --bin-dir DIR` for another
location. Existing unrelated commands are preserved. Rerun the installer if
you move the checkout; remove both installed commands to uninstall.

Both commands use the checkout's mise Ruby version and Gemfile, preserve your
current directory for relative music paths, and forward all arguments. Install
the dependencies above before launching.

To run directly from the checkout:

```sh
mise exec -- bundle exec ruby --yjit bin/rubyplayer [path ...]
```

`mise exec -- bundle exec rake compile` builds the native audio shim (`lib/rubyplayer/native/librp_audio.dylib`), the SPC player (`lib/rubyplayer/native/librp_spc.dylib`), and the GBS, NSF, and HES players (`lib/rubyplayer/native/librp_gbs.dylib`, `librp_nsf.dylib`, `librp_hes.dylib`; all C++, needing `clang++`). `mise exec -- bundle exec rake test` also builds them as a prerequisite. You can build them manually, but a fresh checkout will build them on first launch.

Startup checks every supported runtime dependency before taking over the terminal. Missing Homebrew packages are reported together with one `brew install ...` command. If a bundled library is missing or cannot be loaded, RubyPlayer builds the affected library once and checks it again. This may delay that launch; normal launches do not run Rake or a compiler. If the build fails, its output and a manual retry command are shown. After changing native C/C++ sources, run `mise exec -- bundle exec rake compile` yourself; startup checks whether binaries load, not whether sources are newer.

Any paths given on the command line are scanned into the library on startup, in addition to any roots already remembered from a previous run.

Select **Focus** in the Library pane, then choose a noise recipe in Tracks and press Enter to play it indefinitely. Focus sounds use SoX, are not added to the queue or library history, and stop when normal playback begins.

### Navigation and views

- Press `>` to skip to the next track. Press `<` to restart the current track; within its first three seconds, it plays the previous track from this session if available. With no previous track, it restarts the current track.
- Footer commands occupy three stable rows: playback, queue actions, and controls for the focused pane. Keys and colons are bold; Ctrl combinations use caret notation (`^R` for Ctrl+R). Feature toggles show their current `(on)` or `(off)` state. Narrow terminals show shorter labels and fewer hints. Help stays at the right edge; press `?` for every available command.
- Press `/` to filter current Tracks view live across title, artist, album, composer, and path. Enter accepts filter, as do Up, Down, and Tab, which then move the selection or switch pane as usual; Escape restores previous filter. Each view remembers its filter, cursor, and scroll position.
- Tracks pane title shows current source or folder breadcrumb plus visible item count. Long breadcrumbs keep leaf name and count visible.
- Pane-edge scrollbar appears only when rows overflow viewport.
- Terminals narrower than 72 columns show one full-width pane; Tab switches panes. Wider terminals retain two-pane layout.
- Wide terminals show a **Queued** pane with upcoming tracks and the three latest playback-history entries. Tab selects it while visible; upcoming rows support the same queue actions as the top-level **Playback Queue** view, while history rows are informational. Press `B` to toggle it. It hides when the terminal cannot retain 72 columns for Library + Tracks and while the top-level **Playback Queue** view is selected; hidden Queued is excluded from Tab traversal.
- A **Now Playing** pane between Tracks and Queued shows the playing track's title, album, artist, and rating (album art too in `pane` art mode). It shows whenever the terminal keeps 72 columns for Library + Tracks after Queued; Tab selects it while visible.
- Keys `1`–`6` rate a track and `0` clears its rating: the highlighted track in Tracks or Queued, or the playing track from the Now Playing pane. The Library pane rates nothing.
- Fixed smart views expose **Recently Added**, **Unrated**, **Missing**, **Failed to Scan**, and **Most Played** track lists.
- In **Missing**, press `Ctrl+X` to permanently purge currently filtered/visible tracks and their playback history after confirmation.
- Playback footer shows current track timing and queued next track. During Focus playback it identifies active recipe, infinite duration, paused queue, and next queued track.

### Album artwork

Inline artwork requires iTerm2. Press `V` to cycle placement through off, inset,
pane, and corner; the choice persists in configuration. Press `O` to open the
now-playing view. Other terminals show an artwork placeholder while track
information remains available.

Now Playing separates artist and album information from technical file details.
Playback keys keep working while it is open, on any page: Space plays or
pauses, `<`/`>` go to the previous or next track (the popup follows), and
`[`/`]` seek.
Track numbers show `N of M` when the file tags include a total. The technical
section shows file type, codec, bitrate, sample rate, channels, and bit depth
where available. Chiptunes show system, sound chips, static voice capabilities,
and known intro/loop lengths; VGM/VGZ also show version and declared chip clocks.
NSF/NSFE expansion hardware and SAP/KSS configurations come from file headers.
Voice capabilities describe hardware, not live activity. Copyright, dumper,
and comments appear when available. Opening the popup loads fresh details for
ordinary audio files and chiptunes without a rescan. Unknown fields are omitted.

For VGM/VGZ tracks, Now Playing opens on a full-screen **VGM** live page when
the current playback source is a VGM stream. Press `O` again for the
**Tracker** page, then `O` once more to close Now Playing. `Tab` switches
between **Info** and whichever live page was last open; `Escape` and `Enter`
close from any page. Other formats with one live page close on the second `O`.
The Tracker stays open when the next track also has one (VGM or HES).
The VGM overview covers YM2612/YM3438 FM, SN76489 PSG, and YM2413
OPLL chips when libgme renders them, and uses the whole terminal: one line per
chip (LFO, channel 3 mode, DAC stream rate, timers; PSG noise mode and stereo;
OPLL rhythm keys), every channel (operator keys, note and cents, frequency, an
estimated level bar, pan, instrument, state), a keyboard marking each sounding
channel, the selected channel's voice (YM2612 algorithm diagram and operator
table, OPLL instrument, PSG and DAC detail), estimated operator envelope
shapes, and a few seconds of per-channel note history. Up/Down selects a
channel; `M` mutes or unmutes its libgme voice and `S` solos it. libgme mixes
some channels as one voice (the PSG beside an FM chip, OPLL channels 6–9, OPLL
rhythm), so those mute together. Mute is heard once already-decoded audio
drains. Both VGM pages read VGM commands on one bounded background worker and
follow the sample position already consumed by the audio output, so decoder
read-ahead does not move the display early. Switching between them keeps that
replay. Opening either page deep into a dense track replays in bounded slices
and shows **Catching up** until it reaches the playhead,
including while paused. GME also preserves VGM leading silence so the audio and
register timelines begin together; this also turns off libgme's silence-based
end-of-track detection for VGM, which instead ends on its end command or
header length. Channel state comes from registers; levels and envelope shapes
are estimated from envelope rates and key timing, not measured. Unsupported
chips and partial DAC/stream cases are labeled in the page; for example,
libgme's YM2612 priority makes mixed YM2612/YM2413 files unavailable for OPLL
detail, and YM2151/T6W28 live detail is not provided. Switching to Info or
closing the popup suspends live replay.

The **Tracker** page scrolls a FastTracker-style time grid upward beneath the
playhead. Each row is 50 ms, with the track time and columns for the chip
channels. Note starts, pitch changes, and releases come from the existing
note history. A cell shows a start as `C-4`, a pitch change as `>D-4`, and
a release with a trailing `!` or `===`; a note that starts and glides in one
row shows both (`C-4>D-4`), and one that also ends there stays visible.
`Left`/`Right` moves between channel columns when they do not all fit. This is
a view of timed chip events: VGM and HES have no pattern rows or reliable
tempo, and the page does not infer historical instruments, volume, or effects
from the current registers. Mute and solo remain on the overview page.

For SPC (SNES) tracks, Now Playing opens on a full-screen **S-DSP** live page
that uses the whole terminal: a global row (main/echo volume, FLG, key-on and
end flags), all eight voices (sample, pitch, playback rate, pan, ADSR/GAIN,
envelope level bar, output level, echo/noise/pitch-modulation flags, envelope
phase), an echo/FIR panel with the filter's frequency response, the selected
voice's sample with a waveform and loop point, a map of the SPC's 64 KB RAM, and
the sample directory. Up/Down selects the voice whose sample is shown; `0`–`7`
mute voices (numbered as in the table) and `S` solos the selected voice. Mute
is heard once already-decoded audio drains (up to about 0.85 s with default
buffers). The page shows the state of the audio being heard, refreshed about
20 times a second; finer snapshots would change the emulation itself. `.spc`
playback uses a native port of libgme's SPC player (`ext/rp_spc`), verified
sample-for-sample against libgme; `config.backends[".spc"] = :gme` switches
back to libgme playback (no live page), and the app does so automatically if
`librp_spc.dylib` is missing.

For GBS (Game Boy) tracks, Now Playing opens on a full-screen **GBS** live page
with the same layout as the VGM page: the APU line (power, master volume,
music-driver rate), all four channels (note and cents, frequency, level, pan,
instrument, state), a keyboard, the selected channel's detail (square duty
cycle and sweep, wave output level, noise LFSR width and clock, volume
envelope and length counter), its volume envelope drawn from the last trigger
(or, for the wave channel, the 32-sample wave RAM), and per-channel note
history. Unlike VGM, every value is read from the emulator, so levels and
envelopes are exact. `M` mutes or unmutes the selected channel and `S` solos
it. `.gbs` playback uses libgme's own GBS emulator, vendored with hooks that
record APU state whenever what is heard changes (`ext/rp_gbs`), verified
sample-for-sample against Homebrew libgme; `config.backends[".gbs"] = :gme`
switches back to libgme playback (no live page), and the app does so
automatically if `librp_gbs.dylib` is missing.

NSF and NSFe (NES and Famicom) tracks open on an **NSF** live page laid out
the same way, covering the 2A03 and every expansion chip libgme plays: Konami
VRC6 (two pulses and a sawtooth) and VRC7 (six FM channels, shown with the
YM2413 OPLL panels and VRC7 instrument names), the Famicom Disk System
(wavetable, envelope, and modulation table), Nintendo MMC5 (two pulses and
PCM), Namco 163 (up to eight wavetable channels, with how many are enabled),
and Sunsoft 5B. The 2A03 line names the region (NTSC, or PAL's 2A07 at 50
Hz), frame counter mode, and music-driver rate. Each channel shows its pitch,
level, and settings (duty, envelope, length counter, sweep, linear counter,
LFSR mode, DPCM sample and rate); pulse and noise channels draw their volume
envelope from the trigger, and wavetable channels their wave. A looping DPCM
sample gets the pitch its loop length makes (Sunsoft's DMC bass). Levels are
exact except VRC7's, which are estimated as on the VGM page. Channels mute
and solo by libgme voice. An NSF that sets expansion bits no chip defines
still plays and shows the chips libgme knows. `.nsf` and `.nsfe` play
through libgme's own NSF emulator, vendored with the same kind of hooks
(`ext/rp_nsf`) and verified sample-for-sample against Homebrew libgme on every
fixture, every chip included; `config.backends[".nsf"] = :gme` switches back,
and the app does so automatically if `librp_nsf.dylib` is missing.

HES (PC Engine / TurboGrafx-16) tracks open on an **HES** live page laid out
the same way, for the HuC6280 PSG's six voices (Wave 1-4, Multi 1-2): the chip
line (master balance, VBlank rate), each voice's mode (32-step 5-bit wave,
noise on Multi 1-2, or direct DAC), period and pitch for waves, volume,
balance, and libgme's output gain, the selected wave's 32 samples, and note
history. Noise and DAC voices show no note. Levels are libgme's gain, not the
sound, so they are labeled estimates; the PSG has no envelopes, and libgme
plays neither its LFO nor the CD-ROM ADPCM voice. Each voice mutes and solos
as its own libgme voice. A second `O` opens the same **Tracker** page as VGM
for the six voices; noise and direct-DAC starts show as `NOI` and `DAC`, by the
mode each note began in, since Multi voices switch modes mid-song.
`.hes` plays through libgme's own HES emulator
(`ext/rp_hes`), verified sample-for-sample against Homebrew libgme;
`config.backends[".hes"] = :gme` switches back, and the app does so
automatically if `librp_hes.dylib` is missing.

Artwork comes from embedded pictures in FFmpeg-backed files, falling back to
images in the track's folder (such as `cover.jpg` or `folder.png`). Archived
tracks look beside their entry inside the archive first (rip zips often pack
box art), then in the folder containing the archive. Loading and image
processing run in a background thread and notify the UI through EventBus.

## Testing

```sh
mise exec -- bundle exec rake test
```

## Architecture

Visual walkthroughs (current implementation, with links to source):

- [Component map](docs/explainers/components.md) — responsibilities, thread boundaries, and data flow.
- [Playback sequence](docs/explainers/playback.md) — selection, decoding, native audio, and UI updates.
- [Library scan sequence](docs/explainers/scanning.md) — reconciliation, metadata extraction, and archive restoration.

rubyplayer runs in **one Ruby process with UI, decoder, scan, and native audio threads**, coordinated through a small set of thread-safe primitives. FFmpeg, SoX, and archive extraction use subprocesses:

- **Main thread** — runs the terminal UI loop (`UI::App#run`): waits for keyboard input, events, or a timeout; drains events; and renders when something visible changes. Active playback uses the configured frame rate; idle rendering skips unchanged frames.
- **Scan orchestration thread** — reconciles filesystem state against the database without opening music files, then waits for metadata extraction to finish before processing the next root. Created for each scan request.
- **Extractor pool** — a bounded pool of worker threads created for each extraction batch. Workers open new or changed files through the appropriate backend to pull out metadata (title, duration, subtune count, ...). Expensive libgme/libopenmpt calls use `blocking: true` in the FFI binding, releasing Ruby's GVL so workers can run native work concurrently. FFmpeg-backed metadata uses ffprobe subprocesses.
- **Decoder thread** — owned by `PlaybackEngine`. Opens the play-queue head via a backend, decodes audio, and pumps PCM into the native ring buffer. Focus playback reads SoX-generated PCM through the same thread and audio output, preserving the finite queue. Idle or paused decoding blocks until a command arrives.
- **miniaudio's own callback thread** — native (C), drains the ring buffer at the audio device's pace. It never touches Ruby.
- **Artwork threads** — load and process cover images off the UI thread, returning results through EventBus.

Threads talk to each other through:

- **`EventBus`** — a self-pipe-backed queue. Background threads *publish* events (`:track_started`, `:scan_complete`, ...); the main loop `select()`s on the bus's read end alongside stdin, so it can react to both keyboard input and background progress without polling.
- **Decoder command queue** — a Ruby `Thread::Queue` carries play, pause, seek, and source-switch requests into `PlaybackEngine`'s decoder thread. It is separate from `PlayQueue`, which holds ordered tracks. Some public engine methods also update the track queue synchronously under a mutex.
- **A lock-free SPSC ring buffer** (in the C shim) — the only channel between the decoder thread and the audio callback. The decoder writes, the callback reads; no Ruby object crosses that boundary.
- **Small mutex-guarded state** inside `PlaybackEngine` and `Database` (SQLite access is serialized through a single writer mutex; WAL mode allows concurrent readers).

### Library model

Library data lives in a single SQLite database (`~/.local/share/rubyplayer/library.sqlite3`): `folders`, `tracks`, `track_metadata`, `playback_history`, `playlists`, and `playlist_tracks`. The playback queue remains in memory. A "folder" isn't necessarily a directory — a multi-subtune file (an NSF with 20 songs in it) is modeled as a **virtual folder** whose children are its individual tracks. This unifies "browse a directory" and "browse the subtunes of one file" into the same tree-walking code in `LibraryPane`/`Library#children_of`.

Scans and library-folder removal use **soft deletion**: rows get a `missing` flag, preserving identity and history so they can reappear on rescan. Explicitly purging Missing tracks permanently deletes those track rows and their history, metadata, and playlist entries. Deleting a playlist permanently removes the playlist and its entries while retaining the library tracks.

Archive reconciliation completes before extraction starts. Changed archives
first mark old inner rows missing; extraction restores entries still present.
Removed entries remain missing. See the [scan sequence](docs/explainers/scanning.md)
for this ordering and nested-archive identity.

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
| `duration_formatter.rb` | Shared duration formatting helper used by track formatters, bottom lines, and app rendering. |
| `database.rb` | `Database`: owns the SQLite connection (WAL mode, foreign keys on), the six library tables listed above, and a mutex-guarded transactional `write` API with direct `read` access. Backs up the existing DB file on open and rebuilds from scratch if the schema version doesn't match. |
| `track.rb` | `Track`: a keyword-init `Struct` mirroring a `tracks` row, with `Track.from_row` to build one from a SQLite result hash. This is the value object passed around the whole playback pipeline (queue, engine, UI panes). |
| `library.rb` | `Library`: the query/mutation layer over `Database` — upserting folders/tracks during a scan, reading folders plus source/smart views (`favorites`, `history`, Recently Added, Unrated, Missing, Failed to Scan, Most Played), rating tracks, soft-deleting folder subtrees, user-defined playlists (CRUD, position-ordered entries with move/remove, duplicate), and the track_metadata KV sidecar (full tag sets stored at scan, read on demand). No SQL lives outside this file (and `database.rb`'s schema). |
| `scanner.rb` | `Scanner`: phase 1 of a library scan. Walks a directory tree (or a single file), diffs what it finds against what the DB already knows (by mtime/size), and emits `WorkItem`s for anything new or changed — without opening a single music file. Archives are stat-diffed as a single unit (one mtime check covers every entry inside). Also marks anything that's vanished from disk as missing. |
| `extractor_pool.rb` | `ExtractorPool`: phase 2 of a scan. A bounded thread pool (size configurable, default = CPU core count) that opens each `WorkItem` through the right backend to extract metadata, expands multi-subtune files into virtual folders + child tracks, and flags anything undecodable rather than losing it. Archives are unpacked via `ArchiveCache` and their entries (including nested archives and multi-subtune files) scanned recursively. |
| `archive_cache.rb` | `ArchiveCache`: extracts `.zip`/`.7z`/`.rar` containers into a content-addressed on-disk cache (keyed by path+mtime+size) so the FFI backends — which can only read real files — can decode entries stored inside archives. Uses `bsdtar` (libarchive, bundled with macOS), which reads all three formats and refuses path-traversal entry names. `materialize` resolves a track's `(physical_path, archive_entry)` pair to a real extracted file, chaining through nested archives. The cache directory is safe to delete at any time. |
| `play_queue.rb` | `PlayQueue`: the in-memory playback queue (`Track` objects, not DB rows). Head of the list is "currently playing" when the engine is playing. Supports insert-now/front/end, positional or by-id removal, and bounded undo/redo. |
| `playback_engine.rb` | `PlaybackEngine`: owns the decoder thread, the queue, and the `AudioOutput` device for the process's lifetime. UI threads call its public methods (commands in); it publishes events out via `EventBus`. Handles play/pause/skip/seek, disliked-track auto-skip, and per-track playback-history recording once a track has played past a configurable percentage. Its VGM request API captures consumed audio time and transport identity without disk access. |
| `vgm/reader.rb`, `vgm/cursor.rb`, `vgm/chips.rb`, `vgm/telemetry.rb` | Bounded plain/gzip VGM command reader, state-carrying loop/checkpoint replay, chip capability routing, and a lazy coalescing worker that publishes immutable snapshots. Chip adapters live under `vgm/chips/`. |
| `vgm/note_log.rb`, `vgm/envelope.rb` | Per-chip packed history of note starts, stops, and pitch changes recorded during replay; closed-form estimates of YM2612/YM2413 envelope levels from register rates and key timing. |
| `audio_output.rb` | `AudioOutput`: thin FFI wrapper around the native shim (`RpAudio`) — init/start/stop the device, write float32 stereo frames into its ring buffer, query playback position, pause. One instance per process (the C side holds module-level state). |
| `audio_format.rb` | `AudioFormat`: canonical little-endian float32 interleaved-stereo constants and frame sizes shared by audio producers and consumers. |
| `focus_sounds.rb` | `FocusSound` and `FocusSounds`: immutable catalog of infinite SoX noise recipes, separate from finite library tracks. |
| `focus_player.rb` | `FocusPlayer`: manages the SoX subprocess and reads complete PCM frames from its output pipe for PlaybackEngine. |
| `artwork.rb` | `Artwork`: resolves embedded and folder cover art, caches results, and uses FFmpeg to downscale display images and derive accent colors. |
| `runtime_dependencies.rb` | `RuntimeDependencies`: checks external tools and libraries plus all four bundled native libraries before App loads; rebuilds missing or unloadable bundled libraries once and reports startup failures. |
| `event_bus.rb` | `EventBus`: thread-safe event queue with a self-pipe wakeup, so the main loop's `IO.select` can block on stdin *and* background events simultaneously instead of polling. |
| `level_tap.rb` | `LevelTap`: feeds the bottom-line EQ animation. Runs a Goertzel-algorithm frequency analysis at log-spaced band frequencies over the window of audio the device is playing: `push` (decoder thread) tags audio with its output-timeline frame as it enters the ring; `levels` (UI thread) reads the window ending at `frames_played`. |
| `playback_engine/chip_state.rb` | `PlaybackEngine::ChipState`: live chip state for handles that record native snapshots — pushes each chunk's snapshots into a `ChipTimeline` at the chunk's output frame; returns the SPC snapshot being heard (`spc_live`) or every GBS, NSF, or HES snapshot heard since the last call (`chip_live`), and which kind the track has (`chip_live_kind`). |
| `chip_timeline.rb` | `ChipTimeline`: packed native snapshots (any record class) indexed by output-timeline frame: the latest heard (`at`) or each heard record once, in order (`take_through`). |
| `playback_engine/voice_muting.rb` | `PlaybackEngine::VoiceMuting`: user voice muting for any handle with `#mute` (native SPC, libgme), queued for the decoder thread and tied to the track it targets. |
| `spc/snapshot.rb` | `Spc::Snapshot` (one decoded S-DSP state record) and `Spc::LiveState`. |
| `chip_tracker.rb` | `ChipTracker`: the lifecycle the GBS and NSF trackers share. It reads an engine live state's native snapshots in order, restarts history on a new generation, records note starts, pitch changes, and stops, and builds the live page's view snapshot. |
| `gbs/snapshot.rb`, `gbs/tracker.rb` | `Gbs::Snapshot` (one decoded Game Boy APU record) and `Gbs::Tracker`, which turns the snapshot stream into the VGM live page's channel model and note history. |
| `nsf/snapshot.rb`, `nsf/chips.rb`, `nsf/vrc7.rb`, `nsf/tracker.rb` | `Nsf::Snapshot` (one decoded 2A03-plus-expansion record) and `Nsf::Voices` (libgme's voice numbering per chip set); `Nsf::Chips`, which reads each chip's channels (pitch, level, settings) from a record; `Nsf::Vrc7`, the YM2413 model with VRC7's channel count and instrument names; and `Nsf::Tracker`, which builds the VGM live page's channel model and per-chip note history. |
| `hes/snapshot.rb`, `hes/tracker.rb` | `Hes::Snapshot`: one decoded HuC6280 PSG record (six voices' key, mode, period, gains, and 32-step waves); and `Hes::Tracker`, which builds the live page's channel model (wave, noise, or direct-DAC mode per voice) and note history. |
| `spc/dsp.rb`, `spc/brr.rb`, `spc/fir.rb`, `spc/ram_map.rb` | Pure decoders for the live page: DSP registers, sample directory and BRR samples, echo FIR frequency response, and SPC RAM layout. |
| `track_formatter.rb` | `TrackFormatter`: runs configured formatter lambdas against a track and helper context, then normalizes strings and conditional fragments into validated styled segments. |
| `keymap.rb` | `Keymap`: maps normalized key names to action symbols, merging Ruby-config overrides over sensible single-letter defaults. Matching is case-insensitive. Pane-local bindings shadow global bindings. |
| `theme.rb` | `Theme`: named color palettes for the TUI — a semantic role (`border`, `selection_bg`, `text_muted`, ...) mapped to either a named ANSI symbol or a `"#rrggbb"` truecolor string. `Theme::DEFAULT` reproduces the app's original hardcoded ANSI colors exactly; `Theme::THEMES` holds the selectable named palettes. Widgets receive the active theme per render call, not at construction time, so switching is instant. |

### Format backends (`lib/rubyplayer/backends/`)

| File | Purpose |
|---|---|
| `registry.rb` | `Backends::Registry`: maps file extensions to GME, OpenMPT, FFmpeg, or a native chip player (`NATIVE_BACKENDS`, falling back to GME when its dylib is missing) and lazily instantiates/caches backend objects. Also classifies archive containers (`.zip`/`.7z`/`.rar`), which are "supported" but have no backend of their own — the `ExtractorPool` unpacks them and dispatches each entry to its real backend. |
| `metadata_helper.rb` | Shared backend metadata helpers for presence checks and normalized file extensions. |
| `gme.rb` | `Backends::Gme`: FFI bindings to libgme, plus `Handle` (an open, playable track) and metadata extraction for chiptune formats. Converts libgme's 16-bit PCM output to the app's canonical float32 format. |
| `openmpt.rb` | `Backends::Openmpt`: FFI bindings to libopenmpt, plus `Handle` and metadata extraction for tracker module formats. libopenmpt renders float natively, so no format conversion is needed. |
| `snes_spc.rb`, `snes_spc_lib.rb` | `Backends::SnesSpc`: plays `.spc` through `librp_spc` (handles also expose DSP snapshots, RAM, and voice muting); scanning and metadata stay on libgme. Requiring `snes_spc_lib.rb` loads the dylib and doubles as the availability check. |
| `native_gme.rb`, `gzip_content.rb` | `Backends::NativeGme`: the shared backend and handle for native libgme players (snapshots, voice muting, a sibling `.m3u` as libgme loads it); scanning and metadata stay on libgme. `GzipContent` inflates gzip content (with a size limit) as libgme's file loader does. |
| `gbs_native.rb`, `gbs_native_lib.rb`, `nsf_native.rb`, `nsf_native_lib.rb`, `hes_native.rb`, `hes_native_lib.rb` | `Backends::GbsNative`, `NsfNative`, and `HesNative`: `.gbs` through `librp_gbs`, `.nsf`/`.nsfe` through `librp_nsf`, `.hes` through `librp_hes`. Requiring a `*_lib.rb` binding doubles as the availability check; each attaches the shared player API through `native_gme_lib.rb`. |
| `ffmpeg.rb` | `Backends::Ffmpeg`: probes ordinary audio files with ffprobe and decodes through an FFmpeg subprocess to float32 stereo PCM; supports seeking by restarting decoding at the requested offset. |

### Terminal UI (`lib/rubyplayer/ui/`)

| File | Purpose |
|---|---|
| `app.rb` | `UI::App`: wires every other component together and owns the main loop — key dispatch, event handling, config hot-reload, and the top-level `render`. This is the natural place to look first to see how a keypress becomes an action and how state changes reach the screen. |
| `spc_live_view.rb` | `SpcLiveView`: the full-modal SPC live page. Renders a `Spc::LiveState` into a rectangle, choosing three-column, two-column, or stacked panels by size; graphs are memoized per input. |
| `chip_live_view.rb`, `gb_live_panels.rb`, `nes_live_panels.rb`, `vgm_telemetry_controller.rb` | `ChipLiveView`: the full-modal VGM (and GBS, NSF, and HES, through the Game Boy, NES, and HES panel modules, registered in `NATIVE_PANEL_FAMILIES`) live page, rendering snapshots into a rectangle with three-column, two-column, or stacked panels by size; and the visible-consumer refresh controller. The view does not read files, query the engine, or depend on the Now Playing modal. |
| `chip_tracker_view.rb` | `ChipTrackerView`: the Tracker page (VGM and HES). Buckets the snapshot's packed note history into 50 ms rows of track time and renders a scrolling time grid with a horizontal channel window. Like `ChipLiveView`, it reads only snapshots. |
| `hes_live_panels.rb` | `HesLivePanels`: the HuC6280 PSG parts of `ChipLiveView` (chip line, mode-specific instrument text, estimated levels from libgme's gain, voice panel, wave RAM). |
| `gb_live_panels.rb` | `GbLivePanels`: the Game Boy APU parts of `ChipLiveView` (chip line, instrument text, exact levels, voice panel, volume envelope and wave RAM). |
| `live_glyphs.rb` | Block-character level bars and graphs shared by the live pages. |
| `chip_sample_panels.rb` | `ChipSamplePanels`: wave sparklines, wave graphs, and amplitude-to-attenuation levels shared by the Game Boy, NES, and HES panel modules. |
| `live_panel_renderer.rb` | Panel drawing shared by the live pages: equal-width columns of clipped lines and a one-entry cache per panel. Layout stays in each page. |
| `screen.rb` | `Screen`: the double-buffered renderer described above (`put`/`clear_back`/`flush`), plus truecolor and named ANSI color support. Has no knowledge of panes, tracks, or layout — purely a drawing primitive. |
| `library_pane.rb` | `LibraryPane`: left-hand source tree with queue/history/favorites/Focus, five smart views, and folder hierarchy. Owns folder breadcrumbs, selection, scrolling, and overflow indicator. |
| `list_row_renderer.rb` | Shared stateless track-row construction, styled segment drawing, clipping, theme-color resolution, and section-header text. |
| `playlist_modal.rb` | Snapshot-backed add-to-playlist picker. Owns filtering, selection, duplicate confirmation, and drawing; returns intents to `App` for database mutations. Playlist lists refresh when the picker opens, without queries during redraws. |
| `tracks_pane.rb` | `TracksPane`: interactive item list for every source. Owns filtering, cursor/scroll memory, grouping/sorting, and queue identity while delegating individual track-row drawing. Queue remains flat and ordered. |
| `queued_pane.rb` | `QueuedPane`: snapshot-backed upcoming/history overview with selectable upcoming tracks, queue actions routed through App, cumulative duration, and overflow allocation. History rows are informational. |
| `queue_selection.rb` | `QueueSelection`: shared identity-preserving selection and scrolling for the Playback Queue view and Queued pane. |
| `iterm_image.rb` | `ItermImage`: detects iTerm2 and emits inline-image escape sequences at terminal cell coordinates. |
| `bottom_lines.rb` | Three bottom renderers: `PlaybackLine` (normal/Focus context, next queue item, EQ bars), `StatusLine` (transient feedback), and `HotkeyLine` (context-sensitive bindings). |
| `key_decoder.rb` | `KeyDecoder`: turns raw bytes read from a raw-mode terminal into the normalized key-name strings `Keymap` understands (arrow-key escape sequences, Enter, Tab, Ctrl-combinations, etc). |

### Native audio (`ext/rp_audio/`)

| File | Purpose |
|---|---|
| `rp_audio.c` | A minimal playback shim over vendored miniaudio: owns a lock-free SPSC ring buffer of float32 interleaved stereo frames. The Ruby decoder thread produces PCM via `rp_write`, which retains the GVL for its bounded memory copy; miniaudio's own native callback consumes it and never touches Ruby. Compiled to `lib/rubyplayer/native/librp_audio.dylib` by `mise exec -- bundle exec rake compile`. |
| `miniaudio.h` | Vendored single-header [miniaudio](https://miniaudio.docs/) library — the actual cross-platform audio device backend. Not modified. |

### Native SPC player (`ext/rp_spc/`, `ext/snes_spc/`)

| File | Purpose |
|---|---|
| `ext/snes_spc/` | Vendored SPC700 + S-DSP core, output filter, and resampler from libgme 0.6.5 (LGPL 2.1; see `ext/snes_spc/VENDOR.md` for files, build flags, and the one read-only accessor patch). |
| `ext/rp_spc/rp_spc.{h,cpp}` | C API over that core: a faithful port of libgme's SPC playback control (resampling, gain, fade, silence handling) so output matches libgme exactly, plus S-DSP snapshots recorded once per emulator call (~50 ms). Compiled to `lib/rubyplayer/native/librp_spc.dylib` by `mise exec -- bundle exec rake compile`. `test/snes_spc_parity_test.rb` requires bit-exact output against libgme on every SPC fixture. |

### Native GBS, NSF, and HES players (`ext/gme/`, `ext/rp_gme/`, `ext/rp_gbs/`, `ext/rp_nsf/`, `ext/rp_hes/`)

| File | Purpose |
|---|---|
| `ext/gme/` | Vendored libgme 0.6.5 GBS, NSF, and HES emulators (with every NSF expansion chip and emu2413 for VRC7) and the playback framework, effects buffer, and C API they play through (LGPL 2.1, emu2413 MIT; see `ext/gme/VENDOR.md` for files, build flags, and the accessor and hook patch). Each player compiles the framework plus only its own format. |
| `ext/rp_gme/rp_recorder.h` | What the players share: an emulator subclass that records snapshots from libgme's hooks and maps them from emulator clocks to output frames across leading-silence skipping, keeping those ahead of output so a seek shows the state heard at its target; and the C API plumbing built on it. |
| `ext/rp_gbs/rp_gbs.{h,cpp}`, `rp_gbs_hooks.h` | C API that builds the GBS emulator through libgme's own `gme_new_emu` path (so output is libgme's), plus APU snapshots taken through libgme's `GME_APU_HOOK`/`GME_FRAME_HOOK` macros at each trigger, length or envelope change, and driver call. Compiled with hidden symbols to `lib/rubyplayer/native/librp_gbs.dylib`. `test/gbs_native_parity_test.rb` requires bit-exact output against libgme. |
| `ext/rp_nsf/rp_nsf.{h,cpp}`, `rp_nsf_hooks.h` | The same for NSF and NSFe: 2A03 and expansion chip snapshots at each trigger, key on, length or envelope change, and driver call. The 2A03 and MMC5 frame counters are simulated on copies between hooks rather than advanced (libgme's triangle keeps phase differently across extra time splits while muted). Compiled to `lib/rubyplayer/native/librp_nsf.dylib`; `test/nsf_native_parity_test.rb` requires bit-exact output against libgme on every NSF fixture. |
| `ext/rp_hes/rp_hes.{h,cpp}`, `rp_hes_hooks.h` | The same for HES, built through libgme's `gme_new_emu` path. Compiled to `lib/rubyplayer/native/librp_hes.dylib`; PSG snapshots come from libgme's write and driver hooks alone (the PSG has no envelopes or length counters): one at each key or mode change, even within a driver call, plus the registers each driver call leaves, at most 240 a second. `test/hes_native_parity_test.rb` requires bit-exact output against libgme on every HES fixture, including playlists, seeks, fades, and muting. `.hes` playback uses it by default and falls back to libgme when the dylib is missing. |

### Other directories

| Path | Purpose |
|---|---|
| `test/` | Minitest suite, one file per class above plus `test_helper.rb` (fixture path constant, requires); shared test support is split under `test/support/` (`AppTestSupport` and `AsyncWait`). Run with `mise exec -- bundle exec rake test`. |
| `fixtures/` | Real sample files in every supported format, used by the test suite and for manual verification. |
| `examples/config.rb` | Packaged executable-config starter. First run copies it to `~/.config/rubyplayer/config.rb`; settings remain commented so future built-in default changes still apply. |
| `docs/superpowers/` | Historical design specs and plans; see [`docs/README.md`](docs/README.md) for current documentation guidance. |
| `docs/explainers/` | Current Mermaid component and sequence diagrams, with implementation notes and source links. |
| `docs/ideas.md` | Original freeform brainstorm this project's design was distilled from. |

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

Theme, artwork mode, and Queued-pane preference each use a separate clearly
marked managed block at the end of `config.rb`. Rubyplayer replaces only the
relevant block; user code and comments remain untouched.

Hot reload immediately applies pane widths, Queued preference, seek interval,
theme, keymap, History limit, star glyph, track formatters, frame rate, idle
poll interval, VGM telemetry rate, and the VGM byte limit. Settings captured when constructing audio, scanner, database,
archive cache, playback engine, artwork resolver, or status-line objects require
restart.

### Setting reference

| Setting | Default | Meaning |
|---|---:|---|
| `config.ui.library_pane_percent` | `33` | Library width, integer `1..99`. |
| `config.ui.frame_fps` | `30` | Frame limit; positive integer. |
| `config.ui.vgm_telemetry_fps` | `15` | Maximum VGM live-page snapshot rate (levels still animate at the frame rate), integer `1..30`, also capped by `frame_fps`. |
| `config.ui.vgm_telemetry_max_bytes` | `67108864` | Maximum decompressed VGM/VGZ bytes held for telemetry; positive integer. Above-limit files continue playing without live detail. |
| `config.ui.idle_poll_seconds` | `0.25` | Idle loop wake-up interval. |
| `config.ui.status_message_seconds` | `5` | Status duration; positive integer. |
| `config.ui.resize_settle_seconds` | `0.5` | Delay after resize before re-emitting art. |
| `config.ui.seek_seconds` | `10` | Seek step; positive integer. |
| `config.ui.format_track_grouped` | callable | Grouped-row formatter. |
| `config.ui.format_track_ungrouped` | callable | Flat-row formatter. |
| `config.ui.format_track_queued` | callable | Queued-pane track formatter. |
| `config.ui.queued_pane` | `true` | Enable the read-only Queued pane when width permits. |
| `config.ui.queued_pane_width` | `36` | Queued pane width; positive integer columns. |
| `config.ui.theme` | `"default"` | Id from `Theme::ALL_IDS`. |
| `config.ui.art_mode` | `"off"` | Album-art placement: off, inset, pane, or corner. |
| `config.ui.art_pane_width` | `30` | Now Playing pane width (it holds the album art in `pane` mode). |
| `config.ui.art_display_max_px` | `480` | Longest emitted album-art side in pixels. |
| `config.ui.art_corner_rows` | `8` | Album-art corner height in rows. |
| `config.ui.art_min_rows` | `3` | Minimum usable album-art height in rows. |
| `config.ui.art_inset_max_rows` | `12` | Maximum inset album-art height in rows. |
| `config.ui.art_filenames` | `Artwork::DEFAULT_NAMES` | Folder-art basenames tried before image fallback. |
| `config.ui.art_accent` | `true` | Tint accent color toward current cover art. |
| `config.ui.playlist_recent_count` | `3` | Recent playlists shown in add-to-playlist modal. |
| `config.ui.info_metadata_rows` | `8` | Extra metadata rows shown in info modal. |
| `config.audio.sample_rate` | `"auto"` | Device-native or positive integer Hz. |
| `config.audio.ring_buffer_ms` | `500` | Audio buffer; positive integer ms. |
| `config.audio.decode_chunk_frames` | `16384` | Decode chunk; positive integer frames. Larger bursts use less CPU for FM chiptunes. |
| `config.scanner.thread_count` | `0` | Extractor workers; `0` uses CPU count. |
| `config.library.backup_retention` | `10` | SQLite backups retained. |
| `config.library.history_limit` | `100` | Tracks shown in History. |
| `config.library.history_min_percent` | `5` | Played threshold, `0..100`. |
| `config.library.history_min_seconds_unknown` | `30` | Threshold for unknown durations. |
| `config.library.undo_depth` | `10` | Queue undo/redo depth. |
| `config.library.archive_cache_dir` | `~/.cache/rubyplayer/archives` | Extracted archive cache. |
| `config.library.archive_tool` | `"bsdtar"` | Archive executable. |
| `config.library.metadata_value_limit` | `8192` | Maximum bytes per stored metadata value. |
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
| `config.backends` | `{}` | Extension/backend overrides; dot optional. `.spc`, `.gbs`, `.nsf`/`.nsfe`, and `.hes` default to the native SPC, GBS, NSF, and HES players; for example `".nsf" => :gme` restores libgme playback. |

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
`format`, `title`, `album`, `album_artist`, `artist`, `composer`, `track_number`,
`duration_ms`, `year`, `rating`, `missing`, and `errored`.

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
