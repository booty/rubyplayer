# Output Effects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a session-only, stackable rack of eight character effects to all playback, with a dedicated keyboard-driven panel and clean bypass.

**Architecture:** Apply a native, preallocated stereo DSP rack in the existing miniaudio callback to source frames consumed from the output ring. The UI owns session settings and publishes lock-free per-effect control mailboxes; the callback alone owns effect history, smooths changes, and handles reset requests. Test the same callback orchestration and DSP core directly without a device and exercise the application through its null backend.

**Tech Stack:** Ruby 4, Minitest, FFI, C11 atomics, miniaudio, clang, Rake.

**Spec:** `docs/superpowers/specs/2026-11-06-output-effects-design.md`.

## Global Constraints

- Follow the spec's eight presets and their individual character, fixed order, one intensity each, stacking, session-only settings, clean startup, Focus support and master bypass.
- Off and settled master bypass preserve PCM bit-for-bit. Never change chip emulation or native parity paths. Spectrum and chip views remain source-oriented.
- The callback must not allocate, lock, perform I/O, call Ruby, or do unbounded retry/reset work. Preallocate bounded delay memory for the actual device rate, fail initialization cleanly on allocation failure, and verify atomics used in the callback are lock-free on the target.
- Process only consumed source frames. Pause and underrun emit silence and do not advance effect state; flush resets histories before newly consumed frames, subject to the existing one-device-period race.
- Smooth changes without stale echoes; bound feedback and protect processed output against clipping and non-finite values. Do not touch bypassed PCM for protection.
- TDD: demonstrate relevant failures before each implementation, use `mise exec`, run full suite and RuboCop before the single feature commit. Relevant native compile is required. Work on `main`; no worktrees.

## Review Focus

1. Rapid off/on or bypass changes between callback invocations must reset stale delay history and stay bounded — Task 1 transition tests.
2. Seek/skip during a callback cannot race buffer clearing, undo a ring flush, or play old tails after the next source starts — Task 2 reset/flush tests.
3. Maximum intensity on stacked effects and extreme inputs must remain finite and within output limits — Task 3 stress tests.
4. A short terminal must retain access to every effect and escape safely while normal playback keys still work — Task 4 UI tests.
5. Selecting Focus after a track, and vice versa, must preserve controls while clearing prior source tails — Task 5 integration tests.

## File map

- Create `ext/rp_audio/effects.h`, `ext/rp_audio/effects.c`: independent DSP rack, fixed control format, effect processing and reset.
- Modify `ext/rp_audio/rp_audio.c`, `Rakefile`: own the rack in the device lifecycle, process ring output, publish controls, and compile both sources with all headers tracked.
- Create `test/rp_audio_effects_test.c`, `test/rp_audio_effects_test.rb`: deterministic C harness and Minitest compiler/runner, following `test/rp_audio_ring_test.rb`.
- Modify `lib/rubyplayer/audio_output.rb`: FFI bindings and safe native control publication; add focused tests in `test/audio_output_test.rb`.
- Create `lib/rubyplayer/effects_rack.rb`: session state, effect IDs, intensity and bypass; create `test/effects_rack_test.rb`.
- Create `lib/rubyplayer/ui/effects_modal.rb`, `test/effects_modal_test.rb`, and `test/app_effects_test.rb`; modify `lib/rubyplayer/ui/app.rb`, `lib/rubyplayer/keymap.rb`, help/hint sources as needed.
- Update `README.md` and `docs/explainers/playback.md` to describe controls, source-oriented displays, latency/tail behavior and the new signal path.

## Task 1: Deterministic rack and control state

**Files:** `ext/rp_audio/effects.h`, `ext/rp_audio/effects.c`, `test/rp_audio_effects_test.c`, `test/rp_audio_effects_test.rb`.

**Interfaces:** Define effect IDs 0–7 in fixed processing order: AM Radio, Arcade Cabinet, Tube Amp, Cassette Deck, Mega Bass, Underwater, Music Hall, Echo Chamber. Expose `rp_effects_create(unsigned int sample_rate_hz)`, `rp_effects_destroy(rp_effects *rack)`, and `rp_effects_process(rp_effects *rack, float *interleaved_stereo, unsigned int frame_count, uint64_t controls, uint32_t reset_mask)`. `controls` packs eight 7-bit values (0 means off, 1–100 active intensity), then master bypass in bit 56; `reset_mask` requests per-effect reset. A rack has no shared mutable state: the caller supplies controls and reset requests.

- [ ] Write the Ruby compiler/runner and C assertions for bit-identical zero-control and settled-bypass output, all-off initialization, stereo frame boundaries, zero frames, and deterministic repeated processing at 44,100 and 48,000 Hz. Include rapid enable/off/enable and bypass on/off requests between processing calls: reset masks prevent old delay contents returning. Request a reset of long history and assert the processing call does not loop over its entire allocated delay memory.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/rp_audio_effects_test.rb`; expect failure because the rack API is absent.
- [ ] Implement the rack lifecycle and control decoding; reserve all buffers at creation. Use per-slot generation tags or another demonstrably constant-time logical reset, including safe generation rollover. Smooth parameter/bypass changes over a named short interval; preserve the exact dry samples once bypass settles. Make failed allocations unwind completely.
- [ ] Re-run the focused test; expect success. Run with AddressSanitizer and UndefinedBehaviorSanitizer by compiling the same harness with `clang -std=c11 -fsanitize=address,undefined -Iext/rp_audio test/rp_audio_effects_test.c ext/rp_audio/effects.c -lm -o /tmp/rubyplayer-effects-sanitized` and executing it; expect exit 0.

## Task 2: Native callback and Ruby control bridge

**Files:** `ext/rp_audio/rp_audio.c`, `Rakefile`, `lib/rubyplayer/audio_output.rb`, `test/audio_output_test.rb`, `test/rp_audio_effects_test.c`.

**Interfaces:** Native `rp_set_effect(unsigned int id, unsigned int intensity, int reset)` publishes one effect's value (0 off, 1–100 on) and sticky reset request in one lock-free 64-bit mailbox. Native `rp_set_effects_bypass(int bypass, int reset)` uses a separate mailbox. Ruby `AudioOutput#set_effect(id, intensity, reset:)` and `#set_effects_bypass(bypass, reset:)` forward values under lifecycle protection. The single UI-side publisher sets reset on disabling an effect and on bypass transitions, and CAS-updates each mailbox while preserving any unclaimed reset. For each mailbox the callback attempts at most one strong CAS to claim a coherent value and clear its reset bit; on failure it retains the previously accepted value and any already-claimed callback-owned transition, then retries next callback. Thus callback work is fixed and one effect's disable need not clear another's history.

An effect reset schedules a fade of its outgoing wet contribution to zero, invalidation of its history, and then a fade toward the latest requested target; a rapid re-enable cannot reverse that fade before invalidation. A source flush overrides this sequence and discards old-source history immediately.

Flush has a separate lock-free 64-bit epoch: publish an odd epoch before advancing the ring read cursor and the next even epoch afterward. The callback reads an even epoch before snapshotting/copying ring data and checks it again afterward. If it was odd or changed, discard the copied data, output silence, commit no read cursor, and increment no played frames; try again on the next callback. If stable, reset history when the accepted epoch differs from the callback-owned last-applied epoch, then process. A flush after the final check is the existing allowable already-copied device period and is observed on the next callback. Ruby's existing write mutex must continue to ensure new-source writes begin only after flush returns. Specify and test rollover via an explicit non-wrapping epoch policy that fails safely rather than allowing an old epoch to compare equal; it must never add a retry loop to the callback.

- [ ] Add failing tests for bridge argument forwarding and closed-output rejection; extract the production callback orchestration into a helper callable by the deterministic C harness, with hooks used only in tests to force interleavings. Exercise a short source buffer, pause, rapid off/on and bypass transitions around a mailbox claim, CAS failure, and flush before cursor snapshot, after source copy, before DSP, and during DSP. Include flush finishing between the callback's first epoch read and source snapshot, and the callback observing the interval between cursor advancement and final epoch publication. Assert discarded blocks are silent and do not advance counters; the next source has no stale tail, no reset is lost, no padding is processed, no frame count is invented, and paused state does not advance. Retain the ring stale-cursor test.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/audio_output_test.rb` and `mise exec -- bundle exec ruby -Itest test/rp_audio_effects_test.rb`; expect missing bridge/helper failures.
- [ ] Implement the lifecycle, preallocation/cleanup, mailbox and flush-epoch protocol above; initialize lock-free atomics and fail safely if unsupported. Do not mutate callback-owned buffers from the flushing thread. Invoke the helper for only the consumed `n` frames, then zero the remainder, preserving `rp_frames_played` and ring cursor semantics. Update Rake dependencies and linker inputs for `effects.c` and headers.
- [ ] Run `mise exec -- bundle exec rake compile`, both focused tests and `mise exec -- bundle exec ruby -Itest test/rp_audio_ring_test.rb`; expect success.

## Task 3: Give the eight presets their sound

**Files:** `ext/rp_audio/effects.c`, `test/rp_audio_effects_test.c`.

**Interfaces:** Use Task 1's IDs, control format and DSP entry point. All effects process in that order, with independent parameters derived monotonically from 1–100 intensity; delay and reverb lengths are based on `sample_rate_hz`.

- [ ] Add failing deterministic signal tests: each preset changes a representative stereo signal; Tube adds harmonics to a sine; AM Radio attenuates low and high frequencies relative to mids; Mega Bass boosts low relative to mids; Echo produces a distinct delayed repeat with decaying feedback; Hall spreads an impulse over multiple later times; Cassette and Underwater evolve deterministically over time; Arcade colors a midrange signal. Check independent combinations and both sample rates. Exercise 0, near-full-scale, full-scale and large finite samples plus non-finite input at maximum stacked settings; processed output must remain finite within [-1, 1], and bounded feedback must decay after the input ends. Clean bypass must still preserve arbitrary input bits. Toggle a nonzero echo tail and check that its contribution ramps smoothly down before history is invalidated, and that a rapid re-enable fades in only after reset rather than releasing stale audio.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/rp_audio_effects_test.rb`; expect failures identifying missing effects.
- [ ] Implement bounded DSP primitives: band shaping and saturation for Arcade and AM, soft saturation for Tube, filtered modulated short delay for Cassette, bass shelving for Mega Bass, slowly modulated low-pass for Underwater, multiple short feedback delays for Hall, and a longer feedback delay for Echo. Keep channel processing stereo, feedback strictly stable, and peak protection active only on processed output. Tune reasonable internal constants by listening; do not add user config knobs.
- [ ] Run the focused harness and sanitizer command from Task 1; expect success. Listen to each preset and combinations on representative source material; record the actual audition conditions and any tuning limitations for user review.

## Task 4: Session state and Effects panel

**Files:** `lib/rubyplayer/effects_rack.rb`, `lib/rubyplayer/ui/effects_modal.rb`, `lib/rubyplayer/ui/app.rb`, `lib/rubyplayer/keymap.rb`, relevant help/hint code, `test/effects_rack_test.rb`, `test/effects_modal_test.rb`, `test/app_effects_test.rb`.

**Interfaces:** `EffectsRack` owns eight named effects in the native order, enabled flags, intensities (integer 1–100, default 50), and bypass (initially false). It publishes each affected value and reset request through Task 2's `AudioOutput` methods. Toggling preserves intensity; adjustment clamps to 1–100 in steps of 5; changing an off effect's intensity does not enable it. `UI::EffectsModal#handle_key(key)` returns intents for App, and `#render(screen, theme:, frame:)` draws the viewport. Use `d` globally to open/close Effects (no current pane-local `d` binding); Up/Down select, Left/Right adjust, Enter toggles, `b` toggles bypass, Escape closes. Playback actions use the configured keymap, including defaults Space, `<`, `>`, `[` and `]`, while the panel is open.

- [ ] Add failing state tests for defaults, independent effects, limits, retained intensity, bypass, reset requests for off/on and bypass transitions even when changed rapidly, and no configuration writes. Add modal/App tests for all eight rows, scrolling to the last row on a short terminal, selection and visible state, small widths, close/reopen retention, default and remapped playback key passthrough, clean new session, collisions, help, modal artwork occlusion and redraw.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/effects_rack_test.rb`, `test/effects_modal_test.rb`, and `test/app_effects_test.rb` with the same command form; expect missing classes/actions.
- [ ] Implement the session rack and modal, route through App's existing modal precedence and `modal_active?`, and integrate bindings/help. Route control changes through the single session owner; do not write config. Preserve the underlying screen and artwork on close.
- [ ] Re-run all three focused files and `mise exec -- bundle exec ruby -Itest test/keymap_test.rb`; expect success.

## Task 5: Source integration, documentation, and release checks

**Files:** `test/app_effects_test.rb`, `test/playback_engine_test.rb`, `test/focus_player_test.rb`, `README.md`, `docs/explainers/playback.md`, `docs/memories.md` if a durable new lesson was learned.

**Interfaces:** Normal and Focus playback use the same `AudioOutput`; preserve existing source handoff and `flush` behavior and the rack state between sources.

- [ ] Add a failing integration test that enables two effects, switches normal → Focus → normal, checks settings are retained and flush reset is requested for each handoff; verify bypass does not reset the enabled flags. Confirm startup of a fresh app is clean. Use the native deterministic helper to verify the corresponding history reset actually eliminates a prior source's tail; do not rely on a timing-sensitive null-device capture.
- [ ] Run focused App and playback tests. If they already pass because Task 2's shared flush covers the handoff, preserve them as integration regressions; otherwise confirm the failure and fix the handoff.
- [ ] Fix any source handoff that bypasses flush/reset; update README controls and explain source-oriented displays, clean startup, master bypass, that pause/underrun freezes tails until source frames resume, and that seek/source changes discard them. Update the playback explainer's callback and control flow. Record a durable lesson only if implementation reveals one not already documented.
- [ ] Inspect all callback-reachable code for locks, allocation, I/O, retry loops and unbounded resets. Measure idle/effects-off CPU and callback processing time at 44,100 and 48,000 Hz with all effects at maximum, documenting device, workload and whether each block fits comfortably inside its audio duration; investigate regressions or underruns before proceeding. Test logical-reset generation rollover and use instrumentation or source review to establish reset cost does not scale with delay-buffer length.
- [ ] Run `mise exec -- bundle exec rake compile`, `mise exec -- bundle exec rake test`, and `mise exec -- bundle exec rubocop`; require success. Check `git diff --check` and inspect the complete diff. Record a representative listening pass, or explicitly report that subjective tuning still requires user audition. Commit the whole feature in one commit after checks, then push to the current branch's configured remote as project guidance requires.
