# VGM Tracker Live Page Implementation Plan

> **For agentic workers:** Implement task by task with failing tests first. The project requires one commit per feature, a full test run, RuboCop, and a push to `main` after the feature passes. Do not create a git worktree.

**Goal:** Make Now Playing support an ordered set of live pages, and add a scrolling tracker page after the existing VGM/VGZ chip overview.

**Architecture:** `App` owns the active Now Playing page and playback/telemetry lifecycle. `NowPlayingModal` knows which pages a live kind offers and delegates rendering to the appropriate view. A new `VgmTrackerView` reads the existing immutable VGM snapshots and packed `NoteLog` events; it does not parse files or touch the decoder. GBS, NSF, and SPC retain their current single live page, but use the same page cycling rules so each can gain another page later.

**Tech Stack:** Ruby 4.x, Minitest, the existing `Screen` double buffer and VGM telemetry worker. No new dependencies or native changes.

**Spec:** The user request of 2026-10-12, clarified to mean VGM/VGZ (not GYM); the behavior decisions in this document are the implementation brief.

## Requirements and behavior decisions

- VGM/VGZ: `o` opens on the existing chip overview (`:live`); the next `o` shows the tracker (`:tracker`); the next `o` closes Now Playing. Reopening starts on the overview. GBS/NSF/SPC: first `o` opens their existing live page, second `o` closes. Tracks with no live page: first `o` opens Info, second `o` closes.
- `Tab` toggles between Info and the **last active live page**. Thus, from the tracker, `Tab` shows Info and another `Tab` returns to the tracker. Pressing `o` while on Info closes Now Playing; Info is not part of the `o` live-page sequence. `Escape` and `Enter` always close. Playback keys keep their current behavior on every page.
- VGM telemetry is visible on either VGM live page and suspended on Info, close, or a higher modal. Changing between the two VGM pages must reuse the same controller session and snapshot rather than restarting replay. Seek, track change, and source revision must clear stale content on both views. Artwork is fetched only for Info or after closing, as today.
- The tracker is a **time-grid view**, not an editable module pattern. VGM has no pattern rows or reliable song tempo. Each row represents 50 ms (`2,205` VGM samples); the newest row stays at a stable highlight near the lower part of the viewport while older rows scroll upward. Rows use a fixed-width elapsed `m:ss.cc` timestamp, and each visible chip channel has a labeled column. A note-on displays `C-4`-style pitch, note-off displays a release marker, and an in-key pitch change displays the new pitch with a distinct marker. Unpitched DAC/noise starts display `PCM`/`NOI`; silence is `...`. Multiple events in a row resolve by source-sample order: show the last pitched event, plus a release marker if the row also ends that note, so a short note does not disappear. A release-only row shows the release marker. No historical instrument, volume, tempo, effect, or pattern number is invented from current-only register state.
- Channel order follows the existing `ChipLiveView` order: YM2612, SN76489, then YM2413, each by instance and voice. Columns that do not fit are viewed through a horizontal window; Left/Right moves that window one channel, and the header shows visible range/total. The selected channel is visually distinguished. The view must draw only inside the rectangle given to it, including terminals as small as the existing live-view minimums.
- The tracker shows `Loading`, `Catching up`, and unsupported/error/ended status from the same snapshot/status conventions as `ChipLiveView`. When paused, the highlighted row stops; playback seek or track change resets its viewport and cached note history. VGM telemetry and tracker decoding stop while Now Playing is closed or on Info.
- `M`/`S` mute/solo remain on the chip overview only for this iteration. The tracker hint lists its own Left/Right navigation and close/page keys, not mute controls. This avoids giving horizontal selection an ambiguous audio action. Up/Down and PageUp/PageDown remain overview controls; tracker rows follow the playhead automatically.

## Why the other players need only the shared refactor

The current two-state `:live`/`:info` toggle in `App#toggle_now_playing_page` and `NowPlayingModal#page=` cannot express a second VGM page. Replacing it with a per-kind ordered page list and active-page predicate is the useful shared change. GBS/NSF/SPC already have separate data sources and renderers, so rewriting their views or snapshot paths now would add risk without helping this feature. Their behavior gets regression coverage against the new page controller.

## File map

| File | Responsibility |
| --- | --- |
| `lib/rubyplayer/ui/now_playing_modal.rb` | Declare ordered live pages by kind, validate/set pages, choose renderer and hints, own the tracker view reference. |
| `lib/rubyplayer/ui/app.rb` | Advance `o` through pages, preserve Tab's Info toggle, gate VGM telemetry for both VGM pages, update both views from accepted snapshots, clear both on revision/close. |
| `lib/rubyplayer/ui/vgm_tracker_view.rb` | Render the scrolling time-grid and horizontal channel window from `Vgm::Snapshot` and packed note events. |
| `test/app_now_playing_test.rb` | VGM page sequence, Info return, telemetry visibility/session, seek, track changes, modal cover. |
| `test/app_gbs_live_test.rb`, `test/app_nsf_live_test.rb`, `test/app_spc_live_test.rb` | One-live-page `o` close behavior and Tab regression. |
| `test/now_playing_modal_test.rb` | Page validation, renderer dispatch, hints, tiny-screen/art behavior. |
| `test/vgm_tracker_view_test.rb` | Real and synthetic snapshot rows, event ordering, bounds, statuses, viewport. |
| `README.md` | User-facing keys and tracker limitations. |

## Review focus

1. A seek or track change while tracker is visible must not display notes from the old generation. Test in Tasks 2 and 3.
2. Opening deep into a VGM, then switching overview/tracker while catching up, must not launch another replay session. Test in Task 3.
3. Dense same-row note-on/off/pitch events must render deterministically and short notes must remain visible. Test in Task 2.
4. A narrow/short terminal must not overwrite the modal border or paint outside the content rectangle. Test in Tasks 2 and 3.
5. SPC/GBS/NSF and ordinary audio must preserve opening, Tab, closing, and artwork behavior. Test in Tasks 1 and 3.

---

### Task 1: Introduce ordered Now Playing pages

**Checkpoint:** Complete. Commits `edc5a2bc1dfc5899df74dd560d852e46f2e34362` and `ede18d7117388597b3794f32acfb098e7d8b60ab` pushed to `origin/main`. Verification: 900 tests, 0 failures/errors; RuboCop 188 files, 0 offenses. The temporary tracker state renders the existing VGM overview until Task 3 wires its renderer.

**Files:** Modify `lib/rubyplayer/ui/now_playing_modal.rb`, `lib/rubyplayer/ui/app.rb`; test `test/now_playing_modal_test.rb`, `test/app_now_playing_test.rb`, `test/app_gbs_live_test.rb`, `test/app_nsf_live_test.rb`, `test/app_spc_live_test.rb`.

**Interfaces:** `NowPlayingModal#live_pages` returns `[:live, :tracker]` for `:vgm`, `[:live]` for `:spc/:gbs/:nsf`, and `[]` otherwise. `#live_page?` checks whether `page` is in that list. `#next_live_page` returns the next live page or `nil` at the end. `#page=` accepts `:info` or one of `live_pages` and normalizes unsupported values to `:info`. `App#advance_now_playing_page` uses those methods; `App#toggle_now_playing_info` saves/restores `@last_live_page`, reset on opening a different track or closing.

- [x] Write failing modal tests for each kind's `live_pages`, page validation, and the VGM `:live → :tracker → nil` sequence. Keep `:info` available via Tab, not in `live_pages`.
- [x] Run `mise exec -- bundle exec ruby -Itest test/now_playing_modal_test.rb`; confirm the new tests fail for missing page API.
- [x] Implement the modal page API and replace the hard-coded `:live/:info` setter. Keep the existing live renderer for `:live`; tracker rendering comes in Task 3.
- [x] Write failing App tests for `o` opening/advancing/closing VGM, the one-page kinds closing on their second `o`, no-live Info closing on second `o`, `Tab` returning from Info to the last live page, and `Escape`/`Enter` closing from either VGM live page. Update older assertions that expected `o` to close VGM immediately. Test playback keys on `:tracker` as well.
- [x] Run the relevant `app_*_test.rb` files; confirm page-sequence tests fail before changing App.
- [x] Implement `App#advance_now_playing_page` and `App#toggle_now_playing_info`; route `o` separately from Escape/Enter in `handle_now_playing_key`. Keep keymap `o` unchanged, and let mute/live-navigation dispatch run only on the relevant page.
- [x] Run the affected modal and App tests; expect PASS. This task ends with VGM cycling through a temporary tracker page state, even before it has its own drawing.

### Task 2: Build the VGM tracker renderer from existing note history

**Checkpoint:** Complete. Commits `8540657f46f34200debd0a589f0be9d829232e14` and `fabe18c5df129e2ffa950d0bbd25f6bedc1947e7` pushed to `origin/main`. Verification: 905 tests, 0 failures/errors; RuboCop 190 files, 0 offenses. The tracker is a standalone renderer; Task 3 connects it to Now Playing.

**Files:** Create `lib/rubyplayer/ui/vgm_tracker_view.rb`, `test/vgm_tracker_view_test.rb`.

**Interfaces:** `VgmTrackerView#update(snapshot)` accepts `Vgm::Snapshot` or `nil`; `#render(screen, x:, y:, width:, height:, theme:, track_title:, now_sample:, paused:)` draws in a caller-owned rectangle; `#handle_key(key)` consumes Left/Right; `#snapshot` exposes the current snapshot for stale-state checks. No engine or worker reference is allowed in this class.

- [x] Write failing tests using synthetic `Vgm::Snapshot`/`ChipSnapshot`/`ChannelSnapshot` and packed `Vgm::NoteLog` events. Assert 50 ms row placement, note-on/off/pitch markers, simultaneous-event ordering, a short note's visibility, unpitched DAC/noise labels, and held-note continuity at a pruned history boundary. Use `Vgm::Pitch.note_name` for pitch text.
- [x] Run `mise exec -- bundle exec ruby -Itest test/vgm_tracker_view_test.rb`; confirm failure because the renderer does not exist.
- [x] Implement `#update` to decode each chip's `details[:events]`, keyed by chip ID and voice index. Reuse packed-buffer equality to avoid decoding unchanged histories. Reset on `snapshot.nil?`, generation change, or revision change. Preserve the immutable event order, including equal-sample order; collapse events into 2,205-sample buckets, retaining the last pitch and whether a later note-off occurred in the same bucket.
- [x] Implement `#render` with a stable header, chip/channel headings, elapsed-time gutter, and time-grid rows. Clamp all writes to the supplied rectangle. Anchor the current sample row near the lower third, with blank rows before sample zero. Show status text before data exists and use snapshot `message`/`warnings` where appropriate. Derive the visible channel count from available width; always fit at least one column where the rectangle permits. Define named column/gutter constants with units in names where relevant.
- [x] Implement horizontal window movement and selection with Left/Right; reset on generation/revision changes. Highlight the current row and selected channel using the supplied `theme`, and render a visible-range indicator when columns overflow.
- [x] Add tests at wide and narrow dimensions, outside-rectangle sentinel cells, stable paused position, window bounds, seek/source reset, `Loading`/`Catching up`/error/unsupported statuses, and an empty-chip snapshot.
- [x] Re-run `test/vgm_tracker_view_test.rb`; expect PASS. Run `test/vgm_live_view_test.rb` to confirm the existing overview is unchanged.

### Task 3: Wire rendering and the shared telemetry lifecycle

**Checkpoint:** Complete. Commits `7a362352a0970567dceca208e9ecc3e6d7d4b27e` and `5c0856cd8b5c59091605a8adf2d5c11ce7cc91df` pushed to `origin/main`. Verification: 909 tests, 0 failures/errors; RuboCop 190 files, 0 offenses.

**Files:** Modify `lib/rubyplayer/ui/app.rb`, `lib/rubyplayer/ui/now_playing_modal.rb`; test `test/app_now_playing_test.rb`, `test/now_playing_modal_test.rb`.

**Interfaces:** `NowPlayingModal` receives `tracker_view:` at construction and dispatches `:tracker` to it using the existing full-screen frame helper. `App` creates one `VgmTrackerView` and passes it to the modal. `App#vgm_live_page?` is true for `:vgm` with `page` in `live_pages`, and drives controller visibility. The same accepted snapshot updates both VGM views; each view gets `nil` when the controller session is cleared.

- [x] Write failing modal tests that `:tracker` renders through the full-screen frame, displays a tracker-specific hint, returns no artwork region, and keeps all content inside the frame on tiny terminals. Confirm `:live` and Info still render as before.
- [x] Write failing App tests that switching overview→tracker keeps controller identity/snapshot and visibility, `Tab` to Info suspends telemetry and clears stale rows in both views, `Tab` back restarts replay and returns to tracker, close suspends it, and a higher modal suspends it. Test seek and next-track changes while tracker is visible, including stale telemetry event rejection.
- [x] Run `test/now_playing_modal_test.rb` and `test/app_now_playing_test.rb`; confirm the new assertions fail.
- [x] Add tracker view construction/updates and modal renderer dispatch. Change `tick_vgm_telemetry` to use the shared live-page predicate, and update `handle_vgm_telemetry_event`/stale clearing for both views. Avoid calling `visible = false/true` when changing between two live pages; it clears the replay session. Keep GBS/NSF native snapshot consumption on their existing path.
- [x] Change artwork transitions only when crossing Info ↔ live or closing. `o` overview→tracker should not fetch art, clear telemetry, or reset VGM selection/history. Restrict `M`/`S` to `:live`; pass Left/Right to the tracker on `:tracker`.
- [x] Re-run the affected App and modal tests; expect PASS. Run `test/vgm_realtime_integration_test.rb` and `test/vgm_telemetry_controller_test.rb`; expect PASS.

### Task 4: Document and verify the finished feature

**Files:** Modify `README.md`; adjust affected assertions in the test files above where existing help strings or page-cycle expectations changed.

- [ ] Update the Now Playing navigation section: `o` cycles VGM overview→tracker→close, single-page kinds close on the second `o`, Tab enters/leaves Info, tracker Left/Right moves channel columns. Explain the 50 ms time grid and that VGM supplies no pattern/tempo or historical instrument/effect data.
- [ ] Run `mise exec -- bundle exec rake test`; require zero failures/errors. Run `mise exec -- bundle exec rubocop` (without `-a`) and resolve any offenses in changed Ruby files. No native source changes are planned, so no compile-only run is needed beyond the test task's prerequisite.
- [ ] Review `git diff --check`, `git diff --stat`, and the full diff. Ensure the unrelated `.tmp/readability-pass-oct-12-2026.md` change is neither staged nor overwritten.
- [ ] Stage only this feature's files, commit once, and push `main` to its verified current remote after tests and RuboCop pass, as `AGENTS.md` requires. Record any nonduplicative implementation lesson in `docs/memories.md` before the commit.

## Completion criteria

The three-press VGM flow works, Tab preserves the selected VGM live page, the tracker displays real time-aligned notes without changing playback, telemetry sleeps on Info/close, other formats retain their existing display, and the full suite and RuboCop pass.
