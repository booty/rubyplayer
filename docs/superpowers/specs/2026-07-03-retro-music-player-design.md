# Retro Music Player — Design Document

**Status:** Approved design · **Date:** 2026-07-03 · **Platform:** macOS, Ruby 4.x

A Ruby TUI music library and playback application for retro game music and tracker
formats (`.MOD`, `.VGM`, `.GYM`, `.NSF`, `.SPC`, …), decoded via C libraries and
played through CoreAudio. Personal app; macOS-only for now (cross-platform is a
non-goal). Assumes a Nerd Font with extended glyphs is installed.

---

## 1. Goals & Non-Goals

**Goals**
- A responsive, "fancy" terminal UI for browsing and playing a large retro-music library.
- A robust SQLite-backed library with background scanning, change detection, and metadata.
- A uniform model where directories, archives, playlists, and multi-subtune files are all
  *containers* of tracks.
- Glitch-free playback that never blocks the UI.
- Everything tunable via a hot-reloaded TOML config.

**Non-Goals (for now)**
- Cross-platform support (Linux/Windows) — future goal, not designed for yet.
- Backward-compatible schema migrations — schema mismatch rebuilds fresh (future goal).
- A GUI or config-writing UI — TOML is hand-edited for now.

---

## 2. Cross-Cutting Principles

- **Prefer a config value with a sensible default over a magic number.** Any hardcoded
  constant that a user might reasonably want to change (thread counts, buffer sizes, sample
  rate, refresh rates, limits, thresholds, glyphs, colors) lives in the TOML config with a
  documented default. See §10.
- **Commands flow inward, events flow outward.** The UI sends commands to services and
  subscribes to their events. No service reaches "up" into the UI. This is what makes each
  component independently testable and lets us swap the renderer (or add a GUI) later.
- **Dependencies point inward.** UI → Core and Services → Core; Core depends on nothing.
- **Use Nerd Font glyphs liberally** where they aid clarity (container-kind icons, rating
  stars, EQ bars, transport symbols, missing/errored badges). The glyph table is
  configurable (§10).
- **Never `eval` config.** Format strings and keymaps are parsed with whitelists and fail
  gracefully.

---

## 3. Architecture & Concurrency Model

Single Ruby process, organized as isolated components communicating through thread-safe
queues, with a few long-lived threads.

**Chosen model: threaded single-process (option A).** Rejected alternatives: multi-process
(IPC/serialization complexity, overkill for a personal app) and Ractor-based (FFI + C libs
+ Ractors still fragile in 2026; most gems not Ractor-safe).

**Threads:**
- **Main thread** — input + rendering (the event loop, §8).
- **Scanner thread** — library sync; produces a work list (§6).
- **Extractor pool** — bounded worker pool for metadata extraction (§6).
- **Decoder thread** — turns the current track into PCM, fills the ring buffer (§7).
- **miniaudio callback thread** — created inside C, outside the GVL; drains the ring buffer
  to CoreAudio. Never touches Ruby.

**Why the GVL is a non-issue:** (1) the audio callback runs entirely in C and never touches
the Ruby GVL; (2) FFI decode/IO calls release the GVL while in C, so decoding, metadata
extraction, and filesystem work achieve *true parallelism* across cores.

**The ring buffer** (fixed-size circular PCM buffer) decouples decode from output: the
decoder thread produces samples ahead of time; the audio callback consumes on demand. As
long as it never runs empty, playback is glitch-free regardless of what Ruby is doing.
It also provides natural backpressure — the decoder runs exactly as fast as playback needs.

---

## 4. Component Breakdown

**Core / domain (pure Ruby, no I/O — fully unit-testable)**
- `Library` — in-memory model the UI reads; answers queries (recursive tracks under a
  container, favorites, history). Exposes domain objects, not SQL.
- `Queue` — playback queue + undo/redo stack (max 10 snapshots, configurable). Every
  mutating op pushes a snapshot; emits change events.
- `Container` / `Track` — the unified model. A `Container` yields 0+ `Track`s, each
  identified by `(physical_path, archive_entry, subtune_index)`. Real folders, archives,
  playlists, and multi-subtune files are all `Container`s; regular files are containers-of-one.

**Services (I/O; each on its own thread or thread-safe)**
- `Database` — SQLite access, schema-version guard, startup backup. The only thing that
  touches `.sqlite3`. Single writer (§5).
- `Scanner` — walks folders, cracks containers, extracts metadata, diffs against the DB.
- `PlaybackEngine` — owns the decoder thread, ring buffer, `AudioOutput`, and the
  authoritative `Queue`. Accepts commands, advances the queue, writes history (≥5% rule),
  emits playback state.
- `Backend` interface + `GmeBackend` / `OpenmptBackend` / `VgmstreamBackend` — each wraps
  one C lib via FFI behind an identical interface. `BackendRegistry` maps extension →
  backend with precedence + content sniffing.
- `AudioOutput` — the miniaudio FFI binding; the one class that knows about CoreAudio.
- `ConfigStore` — loads/watches TOML; hot-reloads format strings, keymap, colors, glyphs.

**UI (main thread)**
- `Screen` — double-buffered diff renderer ("draw these cells"); app-agnostic.
- `App` + view controllers — `LibraryPane`, `TracksPane`, `StatusLine`, `HotkeyLine`,
  `PlaybackLine`. Read from Core/services, translate keys (via `Keymap`) into commands,
  render into `Screen`.
- `Keymap` — keys → actions from TOML defaults; active-pane bindings override globals.

---

## 5. Data Model (SQLite)

The container-of-one abstraction lives in **code** (Scanner/Backend treat every file
uniformly). In the **DB and tree view**, single-track files are just `track` rows under
their real parent directory; only genuinely multi-track things (archives, playlists,
multi-subtune files) get their own expandable `folder` row.

**Schema version guard:** SQLite's built-in `PRAGMA user_version`. On startup: back up the
DB (always) → if `user_version` ≠ the build's expected version, rebuild fresh and re-scan
(no backward compat, per decision). DB opened in **WAL mode**.

```sql
folders(                                        -- the tree: real dirs + virtual folders
  id INTEGER PRIMARY KEY,
  parent_id INTEGER REFERENCES folders(id),      -- NULL = top-level root
  name TEXT NOT NULL,
  path TEXT NOT NULL,                            -- absolute path on disk
  kind TEXT NOT NULL,                            -- 'dir' | 'archive' | 'playlist' | 'multitrack'
  track_count INTEGER NOT NULL DEFAULT 0,        -- cached recursive count (drives "(304)")
  missing INTEGER NOT NULL DEFAULT 0,
  mtime REAL, size INTEGER,                      -- change detection for container files
  last_scanned_at TEXT
);

tracks(
  id INTEGER PRIMARY KEY,
  folder_id INTEGER NOT NULL REFERENCES folders(id),
  physical_path TEXT NOT NULL,                   -- decodable file: file / archive / multitrack file
  archive_entry TEXT NOT NULL DEFAULT '',        -- path within an archive; '' = not in an archive
                                                 -- (NOT NULL because SQLite treats NULLs as distinct
                                                 --  in UNIQUE indexes, which would break upserts)
  subtune_index INTEGER NOT NULL DEFAULT 0,      -- subtune within a multi-track file, else 0
  backend TEXT NOT NULL,                         -- 'gme' | 'openmpt' | 'vgmstream'
  format TEXT NOT NULL,                          -- 'nsf','mod','vgm',...
  title TEXT, album TEXT, artist TEXT, composer TEXT,
  track_number INTEGER,
  duration_ms INTEGER,
  file_mtime REAL, file_size INTEGER,            -- stat data for the scanner's change diff
  rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 1 AND 6),  -- NULL = unrated
  missing INTEGER NOT NULL DEFAULT 0,
  errored INTEGER NOT NULL DEFAULT 0,            -- failed to open/decode (distinct from missing)
  added_at TEXT, updated_at TEXT,
  UNIQUE(physical_path, archive_entry, subtune_index)
);

track_metadata(                                  -- uncommon metadata: child key/value table
  track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
  key TEXT NOT NULL, value TEXT,
  PRIMARY KEY (track_id, key)
);

playback_history(                                -- only inserted when >=5% played
  id INTEGER PRIMARY KEY,
  track_id INTEGER NOT NULL REFERENCES tracks(id),
  started_at TEXT NOT NULL, ended_at TEXT NOT NULL
);
```

**Derived, not stored:** *Favorites* = `WHERE rating >= 4`; *History pane* =
`playback_history ORDER BY started_at DESC LIMIT 100`.

**Indexes:** `tracks(folder_id)`, `tracks(rating)`, `tracks(physical_path)`,
`folders(parent_id)`, `playback_history(started_at)`.

**Notes:** timestamps are ISO-8601 TEXT (sortable, human-readable). `missing` is a flag,
never a delete — ratings/history survive a temporarily-gone file. The UNIQUE constraint
makes re-scanning idempotent (UPSERT, no duplicate rows).

---

## 6. Scanning & Library Sync

**"Drag & drop" reality:** dropping a file onto Terminal/iTerm pastes its path as text. The
UI has an **add-path mode** (a keybind opens an input line; bracketed paste enabled) that
accepts pasted/typed paths and hands them to the Scanner. Same path for drag-drop and manual entry.

**Two-phase scan (for responsiveness):**
1. **Fast reconcile pass (single-threaded):** walk the filesystem, `stat` each entry, diff
   against the DB by path + `mtime`/`size`. Classifies everything as
   *unchanged / new / changed / missing* without opening files. Missing → `missing=1`. The
   tree refreshes from this within ~1s even on a big library. This pass produces the work list.
2. **Slow metadata pass (bounded extractor pool):** for *new* and *changed* entries only,
   open via the backend to extract title/album/artist/duration and, for multi-subtune files,
   `track_count`. `thread_count` workers (default = CPU count, configurable) pull from the
   work queue, call the backend via FFI (parallel across cores because FFI releases the GVL),
   and push results to the **single DB writer**. Results stream into the DB incrementally.

**Container cracking (uniform):**
- **Directories** → recurse.
- **Archives** (`.zip/.7z/.rar`) → **libarchive via FFI** (one lib, all three formats).
  Read each entry into a **memory buffer** and hand bytes to the backend (gme/openmpt load
  from buffers → no temp files). Fall back to a temp file only for backends that require a
  path (vgmstream). Process all entries of one archive **within a single worker** (open the
  archive once). *(Phase 2.)*
- **Playlists** (`.m3u/.m3u8/.pls`) → parse, resolve entries relative to the playlist
  location (entries may themselves be multi-subtune files). *(Phase 2.)*
- **Multi-subtune files** (`.nsf/.gbs/.sap/.hes/…`) → open once, read `track_count`, create
  N track rows.

**Pruning:** folders (real or virtual) resolving to **zero supported tracks** are never
shown — enforced by the tree query (`track_count > 0`).

**Concurrency & SQLite:** WAL mode + **single writer** (all writes funnel through
`Database`) → readers never block the writer or vice versa; scanning never freezes the UI.

**Thread-safety caveat:** the extractor pool requires each backend to use *separate*
decoder handles per open with no shared global state (gme/openmpt create independent
contexts — safe). Verified per backend before enabling the pool; degrades to `thread_count=1`
if any backend proves unsafe.

**Startup sequence:** back up `library.sqlite3` → timestamped copy (retention configurable)
→ open DB → check `PRAGMA user_version` → kick off background reconcile of all known roots.

---

## 7. Playback Engine & Backends

**`Backend` interface** (every C lib implements the same shape):
```
open(source, subtune_index) -> handle     # source = path OR byte buffer
read(handle, frame_count)   -> PCM frames # rendered into the canonical format
seek(handle, ms)                          # returns false if unsupported
duration_ms(handle) / track_count(source) / metadata(source, subtune)
close(handle)
```

**Canonical internal format:** float32 interleaved stereo at a fixed rate. Keeps one
continuously-open device and a single ring-buffer format. **Default `sample_rate = "auto"`
= the output device's native rate** (queried at startup), overridable with an integer.
Rationale: gme/openmpt are *synthesizers* — they render natively at any rate with zero
quality loss — so matching the device rate means **no resampling at all** for the majority
of the library; only vgmstream (fixed-rate PCM) needs a single resample, via miniaudio's
built-in converter (no extra dependency).

*Known limitation:* the device native rate can change mid-session (headphones/Bluetooth).
MVP samples it once at startup; miniaudio's converter keeps things working if it changes.
Re-deriving the canonical rate on device change is a Phase-2 enhancement.

**Pipeline:**
```
Queue ──▶ Decoder thread ──▶ [ring buffer] ──▶ miniaudio callback (native) ──▶ CoreAudio
              ▲                                          │
              └────────── commands / position events ────┘
```
- **Decoder thread loop:** decode a chunk → write to ring buffer (blocks when full). On EOF
  → ask `Queue` for the next track (applying the skip-rated-1 toggle) → open it, or stop.
- **miniaudio callback:** pulls frames; on underrun emits silence (and flags it). Never
  touches Ruby.
- **Position** = frames consumed by the device; emitted as events for the UI/progress.
- **Pause** = atomic flag: decoder stops producing, callback emits silence, position frozen
  (instant, click-free). **Seek** = flush ring buffer → `backend.seek` → refill.
  **Skip** = flush → advance queue.

**History & the 5% rule:** engine timestamps `started_at` at track start; on end/skip, if
`played ≥ 5%` of duration, writes a `playback_history` row; else nothing.

**Backend registry:** extension → backend with an **ordered precedence** for overlaps (e.g.
`.vgm`/`.gym` → gme first; broad streamed formats → vgmstream fallback). Each backend can
**sniff** a file to confirm acceptance, so ambiguous cases resolve by content. The map is
config-overridable.

**Equalizer animation:** a lightweight **level tap** computes a small array of per-band
magnitudes (default 16 bands, ~30 fps — both configurable) via a low-resolution FFT of
recent samples. `PlaybackLine` renders bars from the array; degrades to an RMS envelope if
too costly.

**Error handling:** a track that fails to open/decode is flagged `errored` (distinct from
`missing`), logged, skipped; the status line reports it. The decoder thread never dies on
one bad file.

---

## 8. TUI Structure & Rendering

**Event loop (main thread):**
```
loop do
  ready = IO.select([stdin, wakeup_pipe], nil, nil, frame_interval)   # frame_interval ← config (~1/30s)
  decode keypresses (tty-reader) → dispatch through Keymap → emit commands
  drain the event queue (scan progress, playback position, queue-changed, ...) → update view state
  render if dirty (or if animating, e.g. the equalizer)
end
```
Background threads push events into a thread-safe queue and write one byte to a **self-pipe**
in the `IO.select` set → the loop wakes instantly for a redraw, while `frame_interval` paces
the animation.

**Diff renderer (`Screen`):** immediate-mode, double-buffered. Views paint **cells**
(char + fg + bg + attrs) into a back buffer; `Screen` diffs against the front buffer and
emits only changed runs as ANSI (cursor moves + styled spans via `pastel`, truecolor),
then swaps. Cheap, flicker-free.

**Layout** (from terminal size each frame; splits configurable):
```
┌ Library (33%) ─┬ Tracks (67%) ──────────┐
│  (tree)        │  (track list)           │
├────────────────┴─────────────────────────┤
│ Playback line   ♪ now-playing  ▂▄▆█▆▄ EQ │
│ Status line     45 tracks enqueued (u…)  │
│ Hotkey line     [active-pane hotkeys]    │
└───────────────────────────────────────────┘
```
Active pane → bright border; inactive → dim; `TAB` cycles. Bottom-line ordering configurable.

**Library pane:** three fixed special nodes at top (**Playback Queue**, **History**,
**Favorite Tracks**), then the **folder tree**. Tree flattened into visible rows for
selection + scrolling. ↑/↓ move selection, ←/→ collapse/expand. Each row: Nerd Font icon
per `kind`, name, dim recursive `(304)` count.

**Tracks pane:** content follows the Library selection (queue / history-100 / favorites /
a folder's recursive tracks). Grouping (`G`) and sort keys reorder in place; grouped view
uses the album format string, ungrouped the other. History pane hides tracks with <5% played.

**Format strings — parsed, never `eval`'d:** a safe template evaluator interpolates a
**whitelist** of track fields (e.g. `{track_number} {title} {duration} {artist?}`), where
`artist?` means "only if it differs from the album artist." Unknown fields render blank
(graceful). Hot-reloaded live via `ConfigStore`.

**Input & resize:** raw mode; `tty-reader` decodes keys; **bracketed paste** enabled for
dropped/pasted paths. `SIGWINCH` → recompute layout → full redraw.

**State ownership:** `PlaybackEngine` owns the authoritative `Queue` (incl. undo/redo). The
UI sends mutation commands (`enqueue`, `remove`, `undo`, `redo`) and re-renders from
**queue-changed events** carrying a snapshot. UI thread never mutates shared audio state;
decoder thread never reaches into the UI — no locks on UI state.

---

## 9. Keybindings

Driven by the TOML config (§10) with sensible bare-single-letter defaults; active-pane
bindings override globals where they'd collide. Terminal realities resolved:

- **No Cmd combos** (terminals swallow them) → undo/redo default to `u` / `Ctrl-R`.
- **No `Ctrl-Z`** (terminal turns it into `SIGTSTP`/suspend) → avoided.
- **`N` collision** resolved by defaults (global enqueue-at-end vs. pane-local sort);
  fully rebindable in config.

Default actions (rebindable): navigate ↑/↓, expand/collapse ←/→, `TAB` cycle panes,
`SPACE` play/pause, `ENTER` play now, front/back enqueue, `P` select queue, `0` clear
rating, `1`–`6` set rating, `S` skip-rated-1 toggle, group/sort keys, add-path,
undo/redo. The exact default map is finalized during implementation (deliberately not
over-specified here since it's config-driven).

---

## 10. Configuration

- **Config file:** `~/.config/rubyplayer/config.toml`, read-only from the app, parsed with
  `tomlrb`, hot-reloaded on mtime change (format strings, colors, glyphs, keymap apply live).
- **Data dir:** `~/.local/share/rubyplayer/library.sqlite3` (+ timestamped backups).
- **Logs:** file-based via `logger`.

**Tunable values (each with a documented default):** pane split %, bottom-line order,
`sample_rate="auto"`, ring-buffer ms, extractor `thread_count`, EQ `bands`/`fps`, backup
`retention`, history limit (100), the 5% history threshold, undo depth (10), format strings
(grouped/ungrouped), keymap, color theme, and the **glyph table** (container-kind icons,
rating star, EQ chars, transport symbols, missing/errored badges).

---

## 11. Phasing

**Phase 1 — MVP (a genuinely usable player)**
- Scaffold, Ruby 4.x via `.ruby-version`/mise, Bundler, deps, config load, XDG paths, logging.
- SQLite schema + startup backup + `user_version` guard + WAL.
- Scanner for **directories, single files, and multi-subtune files**; two-phase; extractor pool.
- Backends: **openmpt** (trackers) + **gme** (chiptune incl. multi-subtune).
- miniaudio `AudioOutput` + ring buffer + decoder thread; play/pause/seek/skip/auto-advance;
  history + 5% rule.
- Full TUI: `Screen` diff renderer, two panes, tree, track list, status/hotkey/playback
  lines, active-pane border, scrolling, truecolor.
- `Queue` + undo/redo.
- TOML keymap defaults + format strings + hot-reload.
- Ratings (0–6), favorites view, history view.
- Equalizer animation.

**Phase 2 — containers & breadth**
- Archives (**libarchive**) + playlists.
- **vgmstream** backend + broader format coverage; backend sniffing/precedence refinement.
- React to audio-device changes (re-derive sample rate).
- Missing/errored-track cleanup UI.

**Phase 3 — polish / future**
- Selectable RGB color schemes (themes).
- Config-writing / GUI; backward-compatible schema migrations.
- Search/filter; optional mouse support.
- Cross-platform exploration.

---

## 12. Tooling & Dependencies

- Ruby 4.x pinned via `.ruby-version` (recommend **mise**), Bundler.
- Gems: `ffi`, `sqlite3`, `tomlrb`, `tty-reader`, `tty-screen`, `pastel`, `logger`.
- Own thin FFI bindings for: **miniaudio** (vendored single header + tiny shim), **libgme**,
  **libopenmpt**, **libarchive** (Phase 2), **vgmstream** (Phase 2).
- System libs via Homebrew: `libgme`, `libopenmpt`, `libarchive`, `vgmstream` (as phased in).

---

## 13. Testing Strategy

Framework: **minitest** (lightweight, mature, near-stdlib).

- **Pure unit (no I/O — highest value):** `Queue` + undo/redo, `Library` queries, scan
  **diff logic** (against a fake filesystem), format-string template evaluator, `Keymap`
  resolution, `BackendRegistry` precedence, ring-buffer producer/consumer.
- **Integration:** backends decoding **known sample fixtures** (§14) → assert
  duration/track_count/first-frames; DB migration/backup/version-guard; archive/playlist
  cracking (Phase 2).
- **Hard-to-test seams kept thin & mockable:** `AudioOutput` (miniaudio) and `Screen`
  (terminal) hide behind interfaces; everything above tests with fakes. Assert on *emitted
  cells* and *emitted commands*, not on pixels or sound.

The architecture and the test plan share a shape: inward-pointing dependencies mean the
valuable logic has no I/O and is unit-testable with plain objects; the two untestable edges
(sound, terminal) sit behind one interface each.

---

## 14. Test Fixtures (to be supplied by the user)

Small, freely-distributable/public-domain (or self-created) files, kept tiny, checked into
`test/fixtures/`. Desired coverage:

**Bare single-track files**
- `.mod` — classic ProTracker module (openmpt).
- `.xm` or `.it` — a second tracker format (openmpt), to exercise format breadth.
- `.spc` — SNES single-track (gme).
- `.vgm` or `.gym` — Genesis (gme; also exercises the gme/vgmstream precedence rule later).

**Multi-subtune container files** (one physical file, N subtunes — the core model test)
- `.nsf` — NES, many subtunes (the canonical `track_count` test).
- `.gbs` — Game Boy, multi-subtune (a second multi-subtune format).
- *(optional)* `.sap` — Atari, multi-subtune.

**Compressed archives** (Phase 2)
- `.zip` — containing 2–3 supported files (e.g. a `.mod` + a `.spc`).
- `.7z` — containing a couple of modules.
- `.rar` — containing a couple of modules.

**Playlists** (Phase 2)
- `.m3u` — referencing a couple of the bare fixtures above (test relative-path resolution).

**Edge cases**
- An unsupported file (e.g. `.txt` or a tiny `.jpg`) — verify it's skipped.
- A `.zip` containing **no** supported songs — verify the folder is pruned (not shown).
- A truncated/corrupt module — verify it's flagged `errored` and playback continues.
