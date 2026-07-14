# UI Quality-of-Life Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add richer playback feedback, contextual guidance, filtering, breadcrumbs, remembered navigation, responsive layout, scrollbars, and five smart library views.

**Architecture:** Extend existing engine and pane state rather than introducing a global UI store. `PlaybackEngine` exposes playback context, panes own display/navigation state, `App` coordinates input and feedback, and `Library` owns smart-view SQL.

**Tech Stack:** Ruby 4, Minitest, SQLite3, custom ANSI cell renderer

## Global Constraints

- Preserve queue ordering and Focus-outside-queue semantics.
- Preserve configurable keymap and wide two-pane layout.
- Use TDD for every behavioral change.
- Run full suite after each milestone.
- Keep UI keyboard-first and avoid new dependencies.

---

### Task 1: Playback Context and Footer

**Files:**
- Modify: `lib/rubyplayer/playback_engine.rb`
- Modify: `lib/rubyplayer/ui/bottom_lines.rb`
- Test: `test/playback_engine_test.rb`
- Test: `test/bottom_lines_test.rb`

**Interfaces:**
- `PlaybackEngine#state` adds `focus_sound:` and `next_track:`
- `PlaybackLine#render` consumes both fields

- [ ] Write failing engine-state tests for normal, Focus, and stopped queue states.
- [ ] Run focused tests and confirm expected missing fields.
- [ ] Add state fields under existing engine mutex.
- [ ] Write failing footer tests for normal, Focus, stopped-with-next, and narrow widths.
- [ ] Implement mode-aware footer with EQ bars preserved.
- [ ] Add inline comments explaining Focus/queue semantics and truncation.
- [ ] Run focused and full suites.
- [ ] Commit: `Improve playback context feedback`.

### Task 2: Empty and Disabled Feedback

**Files:**
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/tracks_pane_test.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- `TracksPane#handle_action` returns `true`, `false`, or `[:disabled, message]`
- Empty display rows use `type: :empty`

- [ ] Write failing pane tests for contextual empty rows and disabled sort/group outcomes.
- [ ] Write failing app tests for info/rating/disabled status messages.
- [ ] Implement empty row generation/rendering and structured disabled outcomes.
- [ ] Route outcomes through `App#route_to_pane`; add info/rating feedback.
- [ ] Document why pane returns outcomes instead of owning StatusLine.
- [ ] Run focused and full suites.
- [ ] Commit: `Add contextual UI guidance`.

### Task 3: Filtering and Remembered Position

**Files:**
- Modify: `lib/rubyplayer/keymap.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/keymap_test.rb`
- Test: `test/tracks_pane_test.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- Global `/` maps to `:filter_tracks`
- `TracksPane#filter`, `#filter=`, `#clear_filter`, `#selected_queue_track`
- View state keyed by pane mode stores filter, stable selection identity, and scroll

- [ ] Write failing keymap and pane filter tests, including Focus and metadata matching.
- [ ] Write failing accept/cancel/clear app input-flow tests.
- [ ] Write failing queue-removal-through-filter and view-restoration tests.
- [ ] Implement per-view state snapshots, filtering before row grouping, and stable identities.
- [ ] Add filter input mode to App status row and route queue removal by track identity.
- [ ] Document why filtered queue removal cannot use display index.
- [ ] Run focused and full suites.
- [ ] Commit: `Add quick filtering and view memory`.

### Task 4: Breadcrumbs, Scrollbars, Responsive Layout

**Files:**
- Modify: `lib/rubyplayer/ui/library_pane.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/library_pane_test.rb`
- Test: `test/tracks_pane_test.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- `LibraryPane#breadcrumb_for(row)` returns folder ancestry label
- `TracksPane#title` returns mode-aware title with count
- `TracksPane#render` reserves scrollbar column only when needed
- `App::SINGLE_PANE_MAX_WIDTH = 71`

- [ ] Write failing breadcrumb/title/count tests.
- [ ] Write failing scrollbar visibility/thumb-bound tests.
- [ ] Write failing 71/72-column rendering tests.
- [ ] Implement breadcrumb lookup, left truncation, proportional scrollbar, and active-pane-only layout below 72 columns.
- [ ] Document width threshold and scrollbar math.
- [ ] Run focused and full suites.
- [ ] Commit: `Improve pane navigation layout`.

### Task 5: Smart Library Views

**Files:**
- Modify: `lib/rubyplayer/library.rb`
- Modify: `lib/rubyplayer/ui/library_pane.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/library_test.rb`
- Test: `test/library_pane_test.rb`
- Test: `test/tracks_pane_test.rb`
- Test: `test/app_test.rb`

**Interfaces:**
- `Library#recently_added`, `#unrated`, `#missing_tracks`, `#failed_tracks`, `#most_played`
- Fixed row kinds: `:recent`, `:unrated`, `:missing`, `:failed`, `:most_played`

- [ ] Write failing query tests with deterministic fixtures and history aggregation.
- [ ] Implement SQL queries and ordering from approved design.
- [ ] Write failing pane/app tests for fixed-row order and track display.
- [ ] Add fixed rows after Focus and map kinds to Library queries.
- [ ] Document smart-view inclusion/exclusion rules inline.
- [ ] Run focused and full suites.
- [ ] Commit: `Add smart library views`.

### Task 6: Documentation and Final Verification

**Files:**
- Modify: `README.md`

- [ ] Document `/` filter, smart views, breadcrumbs, scrollbar, Focus footer, and narrow layout.
- [ ] Run `mise exec -- bundle exec rake test`.
- [ ] Run real SoX multi-switch smoke test.
- [ ] Run `git diff --check` and confirm clean status.
- [ ] Commit: `Document UI quality-of-life features`.
