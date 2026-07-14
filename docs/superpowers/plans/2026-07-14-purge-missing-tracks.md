# Purge Missing Tracks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add confirmed `Ctrl+X` bulk purge for filtered visible tracks in Missing view.

**Architecture:** `TracksPane` exposes visible Track values, `App` owns command gating and confirmation, and `Library` performs guarded transactional deletion. Queue cleanup reuses existing engine cascade API.

**Tech Stack:** Ruby 4, Minitest, SQLite3, custom terminal UI

## Global Constraints

- Purge only rows with `missing = 1`.
- Target only current filtered visible Missing-view rows.
- Delete playback history before track rows.
- Preserve existing folder removal and confirmation behavior.
- Use TDD and commit completed feature.

---

### Task 1: Purge Data API

**Files:**
- Modify: `lib/rubyplayer/library.rb`
- Test: `test/library_test.rb`

**Interfaces:**
- Produces: `Library#purge_missing_tracks!(ids) -> Array<Integer>`

- [ ] Add failing test proving missing rows/history are deleted and healthy IDs survive.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/library_test.rb`; expect missing method failure.
- [ ] Implement guarded transactional deletes plus count recomputation.
- [ ] Re-run focused test; expect pass.

### Task 2: Visible Targets and Keybinding

**Files:**
- Modify: `lib/rubyplayer/keymap.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/bottom_lines.rb`
- Test: `test/keymap_test.rb`
- Test: `test/tracks_pane_test.rb`

**Interfaces:**
- Produces: global `ctrl_x -> :purge_visible_missing`
- Produces: `TracksPane#visible_tracks -> Array<Track>`

- [ ] Add failing keymap and filtered-visible-track tests.
- [ ] Run focused tests; expect missing binding/method failures.
- [ ] Expose defensive visible Track array and hotkey label.
- [ ] Re-run focused tests; expect pass.

### Task 3: Confirmation Flow

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- Consumes: `TracksPane#visible_tracks`, `Library#purge_missing_tracks!`
- Produces: `App#pending_missing_purge`

- [ ] Add failing wrong-view, filtered-target, cancel, and confirm tests.
- [ ] Run `mise exec -- bundle exec ruby -Itest test/app_test.rb`; expect failures.
- [ ] Add pending purge state, captured IDs, confirmation rendering, queue cleanup, and status feedback.
- [ ] Re-run focused tests; expect pass.
- [ ] Update README control documentation.
- [ ] Run `mise exec -- bundle exec rake test` and `git diff --check`; expect clean pass.
- [ ] Commit `Add missing-track purge command`.
