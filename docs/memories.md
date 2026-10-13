# Implementation lessons

Current as of 2026-10-12. Supplementary implementation notes; AGENTS.md remains
the authority for workflow and invariants.

- Installed launchers select the checkout's explicit mise Ruby version, then
  restore the caller's directory so relative music paths retain their meaning.
  Pin both `BUNDLE_GEMFILE` and `BUNDLE_LOCKFILE`: Bundler 4 exports the latter
  independently, so inheriting another bundle can otherwise modify its lockfile.
- Startup probes all bundled dylibs before loading the UI. Rebuild only missing
  or unloadable targets with `rake -B` (timestamps cannot repair a bad binary),
  under a cross-process lock; probe again after taking the lock because another
  launch may already have built them. Healthy launches never invoke Rake.
- Scan paths need literal, case-sensitive matching. Binary directory-prefix
  ranges avoid SQL wildcard interpretation while allowing indexed comparisons.
- SQLite backups must include committed WAL pages. Use the backup API and
  publish only completed snapshots; copying the main file alone loses data.
- Empty extraction work can follow a deletion-only reconciliation. Always
  recompute folder counts and publish scan completion, even with zero workers.
- Decoder command waits can block indefinitely when idle or paused. Every
  transition requiring work arrives through the command queue.
- Previous-track navigation uses decoder-owned session history, separate from
  the library's minimum-listening-threshold history. Restart seeks to zero;
  going back restores the queue head without creating a manual undo snapshot.
  Retain the last successful start across idle/error transitions; library
  deletion must clear navigation history after any queued current-track skip.
- Frame state needs only a queue entry, not a queue snapshot. Cache Queued's
  duration summary alongside its upcoming snapshot and refresh both together.
- Screen cells are replaced, not mutated. Sharing frozen BLANK across slots
  reduces a 120x40 clear from 4,842 allocations to 42 without changing diffs.
- Footer hints use effective pane bindings and reserve help before fitting
  whole hints. Derive pane, artwork, status, and input geometry from the same
  command-row count; test styled cells to distinguish bold keys from dim text.
  Pass toggle state per render. Grouping indicators report effective view
  state, not the saved preference that ordered queue/playlist views suppress.
- GME metadata iteration owns one metadata-only handle per file and yields
  metadata, subtune index, and total count. Keep handles worker-local and use
  the existing ensure-based cleanup; sibling M3U metadata must remain intact.
  Gate iteration on Registry's multitrack classification so custom backend
  overrides do not create virtual folders the scanner cannot preserve.
- LevelTap needs only the final window of a large PCM chunk. Short chunks must
  retain preceding samples; Goertzel coefficients depend only on construction.
- PlaylistModal snapshots lists on open and caches rows/labels until filtering
  changes. It returns intents to App; database mutations and pane refreshes
  stay in App. Render calls must not query the library.
- NowPlayingModal renders a metadata snapshot. Source audio facts and tagged
  album totals live in metadata extras; totals never come from library counts.
  Existing FFmpeg tracks refresh off-thread on popup open. Match replies to
  both the modal instance and current track to reject stale results. Reserve
  artwork space independently of tag count, and test short layouts against
  the real modal frame so metadata cannot overwrite its hint or border.
- Chiptune hardware extras describe static capabilities, not active voices.
  Read variable hardware from headers (including NSF/NSFE expansion flags),
  reuse one hardware snapshot across subtunes, and decompress only a bounded
  VGM/VGZ header. Mask clock flags before displaying Hz; bit flags can indicate
  dual chips or variants. Preserve uncertainty in legacy FM identification.
- VGM live state uses its own bounded reader/replayer. Keep the decoder as the
  audio authority, preserve VGM leading silence, and derive requests from
  `AudioOutput#frames_played` rather than decoder read-ahead. Coalesce worker
  requests and EventBus tokens; suspend must cancel replay and release the
  cursor without clearing a still-queued notification token. Make both bounded
  decompression and command-boundary validation cancellable, since a small VGM
  can still contain millions of short commands. YM2612 global key/DAC/special
  mode writes belong to port 0; keep pre-1.10 legacy FM clocks explicitly
  ambiguous.
- VGM live page: the worker publishes only the latest snapshot (~15 Hz), so
  anything finer than a refresh (short notes, arpeggios, DAC bursts) must be
  recorded during replay (`Vgm::NoteLog`, carried in checkpoints) rather than
  diffed from snapshots in the UI. Envelope levels are a closed-form model of
  the EG rates, drawn against the sample being heard so bars move between
  snapshots; label them as estimates. libgme's silence detection hears user
  mutes and cannot be safely re-armed mid-track (its silence clock stops while
  ignoring), so the first mute disables it for the track. libgme groups some
  VGM voices (PSG beside FM, OPLL 6-9, rhythm); mute those as a group.
  Single-entry render caches must be keyed per panel, not per item: keying a
  shared slot per operator thrashed and recomputed every frame. The Tracker
  page reads the same `NoteLog` events, so both VGM pages share one controller
  session; set `VgmTelemetryController#visible` only when crossing Info/live
  or closing, because `visible = true` clears the session and restarts replay.
- VGM register-model fidelity: check chip formulas against a reference
  emulator (Nuked-OPN2/MAME), not self-derived expectations — the YM2612 pitch
  test once pinned an octave error. OPN2 frequency high bytes go through one
  shared latch (A4-A6, and AC-AE for special mode) committed by the low write;
  special-mode registers map A9→OP1, AA→OP2, A8→OP3, A2→OP4. Replay is
  resumable per request (stop only between timestamps); never make a command
  budget fatal, and degrade missing DAC/PCM data to a warning, not an error.
- Decoder pacing affects CPU, not just latency: libgme FM emulation in small
  real-time bursts measured ~3x its flat-out cost (cache-cold starts; raising
  QoS did not help). Decode in large chunks and refill the ring with
  hysteresis. Never tie UI animation to decode cadence: `LevelTap` indexes
  pushed audio by output-timeline frame (`frames_played + buffered_frames` at
  write) and analyses the window at `frames_played`.
- Live SPC view (snes_spc backend): replacing a decoder is only safe with a
  bit-exact parity test against the old one; port libgme's control layer
  (fade decided per play call, silence zeroing, lookahead) rather than
  approximating it. Capture live state inside the decoder and tag it with
  output-timeline frames, like LevelTap, instead of running a shadow
  emulator. Verify fixture facts by decoding them, not by reading scan
  output (a joined index list "135" was misread as a bitmask). Full-screen
  views redrawn at 30 fps must memoize derived graphs and avoid per-cell
  allocation (`Screen#fill`, shared frozen cells in `Screen#put`).
- Live GBS view (gbs_native backend): vendor libgme's own `gme.cpp` and
  build the emulator through `gme_new_emu` with a copied type whose
  `new_emu` returns a subclass; that reproduced libgme bit for bit with no
  port. libgme's instrumentation macros (`GME_APU_HOOK`, `GME_FRAME_HOOK`)
  capture state without editing the core. Map emulator clocks to output
  frames with `frames emulated - emu_time` (the leading-silence lead), and
  record during `start_track` too: the silence search emulates the first
  heard note. Check timing against audio onsets with other voices muted
  *before* start_track, or the search sees unmuted audio. Views needing
  every state change (note history) consume all heard snapshots in order
  (`ChipTimeline#take_through`), not just the latest.
- Live NSF view (nsf_native): same approach, sharing `ext/gme` and
  `ext/rp_gme/rp_recorder.h` with GBS. The chips run lazily, so at a hook
  their state is still what the latest write left: record it at that
  write's time, then step frame counters to catch notes that end between
  driver calls. Stepping must be simulated on copies for the 2A03: advancing
  the real APU adds time splits, and libgme's muted triangle (all voices
  are muted during long seeks) keeps phase differently across them, which
  broke parity only after seeks over ~0.3 s. The FDS envelope is the same
  case (libgme's FDS clocks its wave with a `<=` it flags as wrong), and
  raw PCM ($5011) has no enable bit: count it as sounding while its level
  keeps changing. VRC7 reuses the YM2413 model
  (register writes rebuilt from snapshot diffs). libgme numbers voices APU,
  VRC6 (saw first), N163, 5B, FDS, MMC5, VRC7; the page mutes by that.
- Live HES view (hes_native): the HuC6280 PSG changes only when written, so
  libgme's pre-write and driver hooks suffice (no frame-end patch); observe a
  write's effect at the next hook. Record `dac` only in direct-DAC mode:
  elsewhere it is the running output, which muted seek skips leave stale.
  libgme's HES driver hook fires only near 60 Hz, so cap pending writes by
  age (1/240 s) or timer drivers never publish. The shared Tracker page
  labels unpitched starts from the note event (`NoteLog#on unpitched:`), not
  the voice's current kind: Multi voices switch between DDA, noise, and wave.
  Native trackers count output frames since launch; the Tracker latches
  `position − now_sample` once per generation, so ms rounding cannot move
  notes between its 50 ms rows.
