# HES Live View Implementation Plan

> **For agentic workers:** Implement one task at a time with a failing test first, a passing targeted test, and a commit. Use the existing branch `main`; do not create a worktree. Check the current working tree before touching files because UI files may have unrelated edits. Refactor tasks (1 and 6) change no behavior: the existing GBS/NSF/VGM suites are their failing-test-first gate, plus any new seam test named in the task.

**Goal:** Give playing PC Engine `.hes` subtunes a six-channel full-screen live page while preserving libgme audio and metadata behavior.

**Architecture:** Build libgme 0.6.5's HES core into a local native player, record HuC6280 PSG state during decoding with `rp::Recorder`, then feed `Hes::Snapshot` through the shared engine timeline, `Hes::Tracker`, and `ChipLiveView`. Reuse libgme for scanning and `.m3u` metadata. The native player, tracker, and UI are separate reviewable steps.

**Tech Stack:** Ruby 4, ruby-ffi, Rake, C++11/clang++, vendored libgme 0.6.5, Minitest, the existing raw-TTY renderer.

**Spec:** [HES Live View Design](../specs/2026-10-12-hes-live-view-design.md) (proposed, 2026-10-12).

**Status:** Approved 2026-10-12, revised the same day to extract shared GBS/NSF code before HES becomes its third user.

## Global constraints

- Work on `main` without a worktree. Preserve unrelated changes, particularly any concurrent edits to `ui/app.rb` and `ui/now_playing_modal.rb`.
- Keep the audio contract as little-endian interleaved stereo float32. Use `AudioFormat` constants and `blocking: true` for emulating FFI calls.
- Name measured values with units (`_hz`, `_cycles`, `_frames`, `_ms`, `_bytes`). A PSG period register is a timer value, not Hz.
- Do not change libgme's HES synthesis logic. Keep local additions limited to read-only accessors and recorder hooks; document them in `ext/gme/VENDOR.md`.
- Retain the six libgme voice numbers, `.hes` multitrack handling, archive materialization, and `.m3u` metadata. Do not change database schema or scan sequencing.
- Before each commit run its targeted tests. Before the final commit run `mise exec -- bundle exec rake compile`, `mise exec -- bundle exec rake test`, and `mise exec -- bundle exec rubocop`.

## Reuse and extraction

HES is the third native libgme player after GBS and NSF. Where a third copy would otherwise appear, extract the shared piece first, in its own behavior-preserving commit, then build HES on it.

| Extract | Today | After |
| --- | --- | --- |
| FFI binding of the standard `rp_<fmt>_*` player API | `gbs_native_lib.rb` and `nsf_native_lib.rb` repeat the same 15 `attach_function` lines | `Backends::NativeGmeLib.attach_player_api(self, 'rp_gbs')`; each lib file keeps its `ffi_lib` line (requiring it stays the availability probe) and any extras such as NSF's `voice_count` (Task 1) |
| Registry construction of native players with libgme fallback | four near-identical `snes_spc_backend`/`gbs_native_backend`/`nsf_native_backend` methods | one table of native backends and one `native_backend(name)` method (Task 1) |
| `ChipLiveView` dispatch to per-family panel modules | `gb_kind?`/`nes_kind?` chains at summary, level heading, instrument, attenuation, voice lines, detail predicate, and detail panel | one `NATIVE_PANEL_FAMILIES` table (kinds, chip-id prefixes, exact levels) and a uniform `<family>_summary/_instrument_texts/_attenuation/_voice_lines/_detail?/_detail_panel` protocol; GB's `gb_envelope_panel` becomes `gb_detail_panel` (Task 6) |
| App and modal kind lists | `when :gbs, :nsf` in mute and render paths; a backend-name list for Info refresh | derive chip kinds from `@chip_pages.key?(kind)`; add `hes_native` beside the other native names (Task 7) |
| Stereo pan from left/right | `Gbs::Tracker#pan` maps NR51 booleans to `:lr/:l/:r/:none` | `ChipTracker#pan_from(left:, right:)`, used by GBS and HES (Task 5) |

Already shared and reused as is: `rp::Recorder`/`rp::Player` and the `rp::open/start_track/play/seek/capture_now` templates; the Rakefile's `gme_player` task; `Backends::NativeGme` and its `Handle`; `ChipTimeline`/`ChipLiveState`; `ChipTracker#record_note`/`#view_snapshot`; `ChipLiveView#mute_bits` (any channel with `details[:voice]`); `TestSupport::NativeParity`, `RipFixtures`, and `AppTestSupport`.

Considered and rejected: a macro that defines the whole `extern "C"` player API. NSF has its own two-emulator handle, so only GBS and HES would share it, and their wrappers are already one-line calls into `rp::` templates; generated symbols would be harder to find than the duplication is to read.

## Follow-on: HES Tracker page

The next feature adds the VGM Tracker page to HES. Shape this work so that is mostly wiring:

- `Hes::Tracker` must put a `Vgm::NoteLog` in `details[:events]`, timed in the 44.1 kHz samples `ChipTracker#to_sample` produces. `VgmTrackerView` already buckets that format into 50 ms rows, so it can render HES (and GBS/NSF) after a rename to a chip-neutral name.
- Give noise and DDA channels distinct kinds (`:huc_noise`, `:huc_dda`); the tracker's unpitched label (`NOI`/`PCM`) will then map kinds rather than assume VGM's `:noise`.
- Not in scope now: chip trackers count `now_sample` in output frames since launch, not track position, so the follow-on must decide the tracker's time column for them.

## Review focus

1. **Archived `.hes` plus sibling `.m3u`:** native playback must use the extracted sibling playlist and match libgme's selected subtune, title, and length (Tasks 2 and 4).
2. **Leading silence and seek while paused:** the first/captured snapshot must describe the audio at the output position, and note history must reset across the discontinuity (Tasks 3–5).
3. **Rapid PSG gate changes and DDA writes:** a short note must create start/stop events, while direct DAC sample writes must not create thousands of snapshots per second (Tasks 3 and 5).
4. **Noise and DDA on voices 5–6:** mode, pitch, and wave display must not claim a stable note or an active wave oscillator when another mode is selected (Tasks 5 and 7).
5. **Mute/solo and small terminals:** six independent libgme bits must work, and all six rows must remain selectable within the modal frame (Task 7).

## File map and interfaces

| Layer | Files | Responsibility |
| --- | --- | --- |
| Native build | `Rakefile`, `lib/rubyplayer/runtime_dependencies.rb`, `ext/gme/VENDOR.md`, nine upstream `ext/gme/Hes_*` / `hes_cpu_io.h` files | Compile `librp_hes.dylib` and include it in first-launch recovery. |
| Native player | `ext/rp_hes/rp_hes.h`, `.cpp`, `_hooks.h` | Export the standard `rp_hes_*` playback/snapshot API and record six PSG voices. |
| Ruby bridge | `lib/rubyplayer/backends/native_gme_lib.rb` (shared, Task 1), `hes_native_lib.rb`, `hes_native.rb`, `lib/rubyplayer/hes/snapshot.rb`, `backends/registry.rb`, `playback_engine/chip_state.rb` | Bind the dylib, preserve libgme metadata, and carry heard snapshots. |
| Tracker | `lib/rubyplayer/hes/tracker.rb` | Convert native frames and PSG fields into shared channel snapshots and note history. |
| UI | `lib/rubyplayer/ui/hes_live_panels.rb`, `chip_live_view.rb`, `app.rb`, `now_playing_modal.rb` | Render HES rows and panels and connect keyboard controls. |
| Evidence | `test/hes_native_parity_test.rb`, `hes_native_snapshot_test.rb`, `hes_native_backend_test.rb`, `hes_tracker_test.rb`, `hes_live_view_test.rb`, `app_hes_live_test.rb` | Audio parity, timing, mode interpretation, rendering, and controls. |

The native API uses the same signatures as `rp_gbs_*` for `open`, `close`, `load_m3u`, `start_track`, `set_fade`, `ignore_silence`, `play`, `track_ended`, `seek`, `tell_ms`, `mute_voices`, `snapshot_size`, `snapshot_count`, `snapshots`, and `capture_now`. `Hes::Snapshot` exposes `.frame`, `.playing`, and `.triggers` to `ChipTimeline`/`ChipTracker`. `Hes::Tracker#update(ChipLiveState)` and `#snapshot` follow `Gbs::Tracker`.

---

### Task 1: Extract shared native-player plumbing

**Files:** Create `lib/rubyplayer/backends/native_gme_lib.rb`, `test/native_gme_lib_test.rb`; modify `gbs_native_lib.rb`, `nsf_native_lib.rb`, `backends/registry.rb`, `test/registry_test.rb`.

**Interfaces:** `NativeGmeLib.attach_player_api(lib, prefix)` attaches the 15 standard functions to an `FFI::Library` module that has already called `ffi_lib`, with `blocking: true` on `start_track`, `play`, and `seek`. `Registry#native_backend(name)` requires the backend's file, returns `gme_backend` when its class reports `available?` false, and memoizes the instance.

- [x] Write a failing seam test: a fake module that records `attach_function` calls receives all 15 `<prefix>_*` names with the expected argument/return types and blocking flags. Add a registry test that a native backend whose class is unavailable falls back to the shared `Gme` instance, for each of `.spc`, `.gbs`, `.nsf`.
- [x] Run `mise exec -- bundle exec ruby -Itest test/native_gme_lib_test.rb` and `test/registry_test.rb`; confirm the new tests fail.
- [x] Implement the helper and switch both lib files to it; replace the per-backend registry methods with the table. Run the GBS/NSF backend, parity, snapshot, and registry tests, then the full suite and RuboCop. Commit.

### Task 2: Vendored HES player with bit-exact audio

**Files:** Add upstream `ext/gme/Hes_Apu.{h,cpp}`, `Hes_Apu_Adpcm.{h,cpp}`, `Hes_Cpu.{h,cpp}`, `Hes_Emu.{h,cpp}`, and `hes_cpu_io.h`; create `ext/rp_hes/rp_hes.{h,cpp}`, `rp_hes_hooks.h`, `lib/rubyplayer/backends/hes_native_lib.rb`, `test/hes_native_parity_test.rb`; modify `Rakefile`, `lib/rubyplayer/runtime_dependencies.rb`, `ext/gme/VENDOR.md`.

**Interfaces:** Produce `librp_hes.dylib` and the playback portion of `Backends::HesNativeLib` (`rp_hes_open`, `close`, `load_m3u`, `start_track`, `set_fade`, `ignore_silence`, `play`, `track_ended`, `seek`, `tell_ms`, `mute_voices`). Keep the wrapper's snapshot type private until Task 3. `rp::Recorder<Hes_Emu, PrivateSnapshot>` may use a minimal private struct with `frame` and `triggers` so the shared `rp::Player` plumbing works before snapshot recording is added.

- [x] Write `test/hes_native_parity_test.rb` using `TestSupport::NativeParity` and `TestSupport::RipFixtures`. Compare audible track 1 from **all four** HES rips for 3–5 seconds at 48 kHz. Add cases for default and ignored silence, 1-second fade, forward/backward seeks, mute bit 0 or 4, and an archived rip's sibling `.m3u`. Assert the reference produces audible PCM; the helper already does this.
- [x] Run `mise exec -- bundle exec ruby -Itest test/hes_native_parity_test.rb`; expect failure because `HesNativeLib` and the dylib do not exist.
- [x] Copy the nine files from the [upstream 0.6.5 `gme/` directory](https://github.com/libgme/game-music-emu/tree/0.6.5/gme), not `master`. Extend `gme_player` in `Rakefile` with `HES_DYLIB`, `types: %w[HES]`, and the four HES `.cpp` files plus `GME_FRAMEWORK`. Add this target to `compile`. Add `librp_hes.dylib` to `RuntimeDependencies::NATIVE_LIBRARIES` and its tests.
- [x] Implement the standard playback C API by copying `gme_hes_type` and replacing only `new_emu` with the local subclass, as GBS does. Keep `rp_hes_hooks.h` inert in this task. Bind the C API in `hes_native_lib.rb` with `NativeGmeLib.attach_player_api` (Task 1), which already marks `start_track`, `play`, and `seek` `blocking: true`. Append the HES source manifest, flags, and source URL to `VENDOR.md`.
- [x] Run `mise exec -- bundle exec rake compile` and the parity test. Fix differences at the wrapper/build boundary without changing libgme synthesis. The HES dylib must export only `rp_hes_*` symbols. Commit the independently testable native player.

### Task 3: Heard-time PSG snapshots

**Checkpoint:** Complete, with three deliberate departures found during implementation. (1) No frame-end or after-write source patch: the PSG changes only on writes, so libgme's pre-write `GME_APU_HOOK` and `GME_FRAME_HOOK` observe each write's effect at the next hook, labeled at the write's clock; a `$804`/`$805`/`$807` write that would overwrite an unrecorded key or mode change records it first. (2) `dac` is recorded only in direct-DAC mode: in wave and noise modes it is libgme's running output, which muted seek skips leave stale. (3) A track that sounds at once has no earlier state to clamp to frame 0; its first record is its first driver call, within one VBlank. Real rips record 62–212 snapshots/s.

**Files:** Extend `ext/rp_hes/rp_hes.{h,cpp}`, `rp_hes_hooks.h`, local patches in `ext/gme/Hes_Emu.{h,cpp}` and `Hes_Apu.h`; create `lib/rubyplayer/hes/snapshot.rb`, `test/hes_native_snapshot_test.rb`; extend `lib/rubyplayer/backends/hes_native_lib.rb` and `ext/gme/VENDOR.md`.

**Interfaces:** Export `rp_hes_snapshot_size/count/snapshots/capture_now`. `Hes::Snapshot.unpack(packed, index)` returns an immutable record with `frame`, `playing`, `triggers`, `master_balance`, `selected_channel`, `period[6]`, `control[6]`, `balance[6]`, `noise[6]`, `dac[6]`, `wave` (192 bytes), `output_left[6]`, `output_right[6]`, `vblank_period_cycles`, and `cpu_clock_hz`. The snapshot struct is **268 bytes** in that field order; assert `sizeof` in C++ and in a Ruby unpack-layout test. `frame` is signed int32; `output_left/right` copy `Hes_Osc::volume[2]` as signed int16, and the other fields are unsigned. The UI uses the magnitude of those gains. `wave` may stay a packed binary String in Ruby to avoid allocating 192 integers per record.

- [x] Write failing ABI/timing tests: a hand-packed 268-byte record with distinct values in every field unpacks exactly in Ruby (including signed output gains); an HES fixture produces records with nondecreasing relative `frame` values; the first play includes a frame-zero baseline after leading-silence skip; `capture_now` after seek returns the state heard at frame zero; a 5-second run over the four real fixtures has bounded record counts. Pin a gate-on and gate-off on the same voice less than one VBlank period apart, with the correct trigger bit. Use a real rip when it exhibits the transition; otherwise add a tiny test-only HES program in `test/support/hes_builder.rb` that writes PSG control `$804` on and off in one driver call.
- [x] Run `mise exec -- bundle exec ruby -Itest test/hes_native_snapshot_test.rb`; expect the missing snapshot ABI to fail.
- [x] Add read-only `Hes_Emu::rp_apu()` / `rp_play_period()` and `Hes_Apu::rp_osc(i)` / `rp_master_balance()` / `rp_latch()` accessors. The emulator's clock is 7,159,091 Hz (`setup_buffer`); expose/read its actual `clock_rate()` for the snapshot. `Hes_Apu::osc_count` is six. Copy the six oscillators' actual `period`, `control`, `balance`, `noise`, `dac`, 32-byte `wave`, and left/right `volume` fields; do not infer those from the last register write alone.
- [x] Wire `GME_APU_HOOK` in `Hes_Emu::cpu_write_` and `GME_FRAME_HOOK` in its IRQ path through `rp_hes_hooks.h`. Add a local after-write hook immediately after `apu.write_data(t, addr, data)` to observe the resulting state at the same clamped `t`; add a frame-end hook immediately before `apu.end_frame(duration)` so the last writes in an emulation frame are not lost. Record audible gate/mode transitions and retriggers immediately, coalescing ordinary period/balance/wave updates to at most about 240 Hz. DDA `$806` sample writes update the latest value but do not each queue a snapshot or retrigger a note. Use `rp::Recorder` to map emulator clocks through libgme's leading-silence skip to output frames; use its `capture_now` path after seeks. Document only these local source edits in `VENDOR.md`.
- [x] Repeat `mise exec -- bundle exec rake compile`, `test/hes_native_snapshot_test.rb`, and the Task 2 parity test. The parity test is a hard gate: every PCM sample must still match libgme. Commit snapshot recording.

### Task 4: Route HES playback and snapshots through the engine

**Files:** Create `lib/rubyplayer/backends/hes_native.rb`, `test/hes_native_backend_test.rb`; modify `lib/rubyplayer/backends/registry.rb`, `lib/rubyplayer/playback_engine/chip_state.rb`, `test/registry_test.rb`, and relevant engine chip-state tests.

**Interfaces:** `Backends::HesNative < NativeGme` supplies `Native.new(lib_file: 'hes_native_lib', lib: :HesNativeLib, prefix: 'rp_hes', snapshot_type: Hes::Snapshot, label: 'HES', max_bytes: 4 * 1024 * 1024)`. `Registry#backend_name_for('.hes')` returns `:hes_native`; `PlaybackEngine#chip_live_kind` returns `:hes` for `Hes::Snapshot`.

- [ ] Write failing tests for registry routing, one native HES handle's `read`, `seek`, `mute`, `take_snapshots`, and `capture_now`, and unchanged metadata/track count/title/length from `RipFixtures.path(:air_zonk)` and one archive rip. Test that the engine reports `:hes`, returns heard snapshots, and resets generation on seek/track change.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/hes_native_backend_test.rb` and `test/registry_test.rb`; expect failure on the missing backend/route.
- [ ] Add `HesNative` with the `NativeGme` handle. Register `.hes` as one more row in Task 1's native-backend table. Add `Hes::Snapshot` to `CHIP_LIVE_KINDS`; do not add HES-specific frame arithmetic to `PlaybackEngine`. Existing `ChipTimeline` owns output-frame timing and the post-seek capture.
- [ ] Run targeted backend, registry, parity, and snapshot tests. Commit the playable HES route.

### Task 5: Convert PSG state to notes and channel rows

**Files:** Create `lib/rubyplayer/hes/tracker.rb`, `test/hes_tracker_test.rb`; update `lib/rubyplayer/hes/snapshot.rb` only if the tests reveal a format-field need.

**Interfaces:** `Hes::Tracker < ChipTracker`. Emit one `Vgm::ChipSnapshot` with id `huc6280:0`, name `HuC6280 PSG`, six `Vgm::ChannelSnapshot`s with ids `huc6280:0:0` through `:5`, and chip `details[:events] = Vgm::NoteLog#packed`. Each channel carries `details[:voice] = 0..5`, `details[:release_sample]`, `details[:pitch_cents]`, plus the mode-specific fields used in Task 7.

- [ ] Write failing tracker tests from small constructed `Hes::Snapshot` records: control bit 7 gates a channel; bit 6 selects DDA; noise bit 7 selects noise only for voices 4–5; a gate retrigger creates two note starts; off creates a release/history stop; pitch change while held creates a history pitch event; a generation change clears stale notes. Include one real fixture's snapshots to prove the six rows are fed by native playback.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/hes_tracker_test.rb`; expect the missing tracker to fail.
- [ ] Build mode-specific channel details. For a positive wave period use `pitch_hz = cpu_clock_hz.fdiv(64 * period)`; for period zero, noise, and DDA use `nil`. Put `mode: :wave/:noise/:dda`, `period_register`, 32 wave samples (0–31), `noise_rate_code`, `dac_sample`, control volume, current left/right gain, and balance in the details with explicit units where measured. Use `:huc_wave`, `:huc_noise`, and `:huc_dda` kinds. Derive pan from actual output gain with `ChipTracker#pan_from`, extracted from `Gbs::Tracker#pan` in this task (GBS tests stay green). Record note history with `ChipTracker#record_note`; no MIDI pitch is needed for noise/DDA. The selected voice's mute bit comes from `details[:voice]`.
- [ ] Run the tracker and native snapshot tests. Commit the model.

### Task 6: Extract ChipLiveView's native panel-family dispatch

**Files:** Modify `lib/rubyplayer/ui/chip_live_view.rb`, `gb_live_panels.rb`, `nes_live_panels.rb`; test through `test/gbs_live_view_test.rb`, `test/nsf_live_view_test.rb`, and `test/vgm_live_view_test.rb`.

**Interfaces:** `ChipLiveView::NATIVE_PANEL_FAMILIES` maps a family prefix (`:gb`, `:nes`) to its channel kinds, chip-id prefixes, and whether levels are exact. Each panel module implements `<family>_summary(chip)`, `<family>_instrument_texts(channel)`, `<family>_attenuation(channel)`, `<family>_voice_lines(row, width)`, `<family>_detail?(channel)`, and `<family>_detail_panel(row, width, rows)`. `ChipLiveView` dispatches through one `native_family(channel)` lookup; VGM chips keep their explicit branches.

- [ ] Add a failing test that a view with a stub family module registered in the table renders that module's summary, instrument text, and detail panel, so the protocol (not the GB/NES branches) is what is exercised. Keep every existing GBS/NSF/VGM view assertion unchanged.
- [ ] Rename `gb_envelope_panel` to `gb_detail_panel`, add `gb_detail?` (always true, as `envelope?` assumes today), and replace each `gb_kind?`/`nes_kind?` chain with the table lookup. Comment the naming convention where the dispatch happens, since the protocol's method names are built from the family prefix.
- [ ] Run the three view test files, the full suite, and RuboCop. Commit.

### Task 7: Live page, controls, and documentation

**Files:** Create `lib/rubyplayer/ui/hes_live_panels.rb`, `test/hes_live_view_test.rb`, `test/app_hes_live_test.rb`; modify `lib/rubyplayer/ui/chip_live_view.rb`, `ui/app.rb`, `ui/now_playing_modal.rb`, `README.md`, and `docs/memories.md`.

**Interfaces:** `HesLivePanels` implements Task 6's protocol: `hes_summary`, `hes_instrument_texts`, `hes_attenuation`, `hes_voice_lines`, `hes_detail?`, and `hes_detail_panel` (the wave graph). `ChipLiveView` dispatches those kinds to this module through one `NATIVE_PANEL_FAMILIES` row (Task 6), with exact levels off. `UI::App#@chip_pages[:hes]` pairs `ChipLiveView.new(source: 'HES')` with `Hes::Tracker.new`.

- [ ] Write failing view tests at the same screen sizes as `test/gbs_live_view_test.rb`: all six channels accessible, no writes outside the rectangle, header shows HES, selected wave voice shows its 32 five-bit samples, and noise/DDA show their own mode details without a note. Assert the level header says `Level (est.)`. Assert `selected_mute_bits` for indices 0–5 is `[1, 2, 4, 8, 16, 32]` and `all_mute_bits == 0x3f` even when channels are silent.
- [ ] Write failing app tests using the real `air-zonk.hes` plus sibling `.m3u` in `AppTestSupport`'s temporary library: Now Playing opens on `HES LIVE`, Tab shows Info and returns, `M` mutes the selected voice, `S` solos it, and seeking clears old history. Follow `test/app_gbs_live_test.rb` and shared async polling; do not launch the raw TTY app in tests.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/hes_live_view_test.rb` and `test/app_hes_live_test.rb`; expect missing dispatch/route failures.
- [ ] Implement HES rendering in its own panel module: chip clock and VBlank period, per-voice mode and balance, a 32-sample 5-bit wave graph in the detail panel, noise rate code/LFSR clock for Multi voices, and DAC sample value in DDA mode. Label level as estimated from emulator gain. Do not draw an envelope graph or invent a pitched note for noise/DDA. Cache only derived graphs, using the existing bounded panel cache.
- [ ] Add `hes: [:live]` to `NowPlayingModal::LIVE_PAGES` and `:hes` to `App#@chip_pages`; replace App's `when :gbs, :nsf` cases with `@chip_pages.key?(kind)` so HES needs no new branch; add `hes_native` to the Info metadata refresh backend list. Add `huc6280` to `ChipLiveView::CHIP_ORDER` and one `NATIVE_PANEL_FAMILIES` row. Preserve current VGM tracker-page behavior if another agent has changed that code. Update README's format/live-view and build sections, and add one concise tested lesson to memories.
- [ ] Run the targeted view/app tests, then `mise exec -- bundle exec rake compile`, `mise exec -- bundle exec rake test`, `mise exec -- bundle exec rubocop`, and `git diff --check`. Inspect parity, snapshot-count, seeking, and both terminal sizes before committing. Commit the page and docs.

## Completion check

The work is complete when all four `RipFixtures.names('hes')` paths decode bit-exactly against libgme; the native snapshots match heard time across leading silence and seeks; the tracker retains rapid note edges without a DDA-snapshot flood; and the six-voice Live page, Info tab, mute, solo, scrolling, and archive `.m3u` paths pass their tests. Record any libgme HES limitation in the UI wording or README rather than claiming unsupported chip behavior.
