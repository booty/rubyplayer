# Editable Queued Sidebar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make the visible Queued sidebar a focusable, editable queue view with shared queue-selection invariants and correct focus recovery when it disappears.

**Architecture:** Add a focused `QueueSelection` state object that owns ordered upcoming-track selection, identity preservation, scrolling, and queue-index resolution without owning rendering. `TracksPane` delegates queue-mode selection to it, while `QueuedPane` uses it for upcoming rows and retains its own history/section rendering. `App` exposes only currently visible panes to Tab, routes queue actions through the active queue selection, and marks Queued active in layout, hotkeys, and help when focused.

**Tech Stack:** Ruby 4.x, Minitest, custom double-buffered `Screen`, existing `ScrollableList`, `ListRowRenderer`, `PlaybackEngine`, and `Keymap`.

## Global Constraints

- Only upcoming rows are selectable and editable; history rows remain visible but decorative.
- Hidden Queued is excluded from Tab traversal.
- If Queued is active when hidden by toggle, resize, or top-level Playback Queue selection, focus advances to the next eligible pane in visual order, wrapping when needed.
- The top-level Library `Playback Queue` view keeps its existing full-list behavior.
- Queue mutations call existing engine APIs; snapshots are never mutated directly.
- Removing the currently playing head continues through `PlaybackEngine#remove_at` for decoder-thread safety.
- Existing duration totals, overflow rows, formatters, and three-history-row behavior remain unchanged.
- Do not add a new keyboard shortcut for pane focus; existing Tab behavior is extended to visible Queued.
- Run focused tests, RuboCop on changed Ruby files, and the full suite before completion.

---

### Task 1: Add shared queue-selection state

**Files:**
- Create: `lib/rubyplayer/ui/queue_selection.rb`
- Modify: `lib/rubyplayer.rb:30-36` to require the new class before panes
- Create: `test/queue_selection_test.rb`

**Interfaces:**
- `RubyPlayer::UI::QueueSelection.new`
- `#replace(items)` accepts an ordered `Array<Track>`, preserves the selected track by object identity/id when possible, then clamps selection.
- `#selected_track` returns the selected upcoming `Track` or `nil`.
- `#selected_index` returns the selected index within the current visible item set or `nil`.
- `#handle_action(action)` handles `:nav_up`, `:nav_down`, `:nav_page_up`, and `:nav_page_down`, returning whether it changed/handled selection.
- `#set_page_size(height)` records the rendered viewport height, using `ScrollableList::PAGE_SIZE_FALLBACK` until first render.
- `#follow_selection(height)` keeps the selected row inside the viewport and clamps scroll.
- `#visible_items(height)` returns the upcoming slice visible in a sidebar viewport and the count remaining after it, without including history or overflow rows.

- [ ] **Step 1: Write failing unit tests**

Add tests proving:

```ruby
selection.replace([first, second, third])
selection.handle_action(:nav_down)
assert_same second, selection.selected_track

selection.replace([first, third])
assert_same third, selection.selected_track # identity survives removal before it

selection.replace([])
assert_nil selection.selected_index # empty replacement has no target
```

Also test page movement by the configured page size, clamping at both ends,
and `visible_items` returning a bounded slice plus trailing hidden count.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```sh
mise exec -- bundle exec ruby -Itest test/queue_selection_test.rb
```

Expected: FAIL because `RubyPlayer::UI::QueueSelection` does not yet exist.

- [ ] **Step 3: Implement the minimal state object**

Store a duplicated ordered item array, selected identity, selection index,
scroll offset, and page size. Use the existing `ScrollableList` follow/clamp
math internally. `replace` must search by `equal?` first and `id` second so a
fresh queue snapshot still preserves the logical track. `visible_items` must
never return an overflow sentinel; callers own section/header rendering.

- [ ] **Step 4: Run focused tests and verify pass**

Run the same focused command. Expected: all `QueueSelection` tests pass.

---

### Task 2: Integrate QueuedPane selection and rendering

**Files:**
- Modify: `lib/rubyplayer/ui/queued_pane.rb:6-115`
- Modify: `test/queued_pane_test.rb`

**Interfaces:**
- `QueuedPane#handle_action(action)` delegates queue navigation to its
  `QueueSelection` instance.
- `QueuedPane#selected_track` returns only the selected upcoming track.
- `QueuedPane#selected_track_index` returns the selected upcoming index or nil.
- `QueuedPane#render(..., active:)` highlights the selected upcoming row only
  when `active: true`; history/header/empty/overflow rows never select.

- [ ] **Step 1: Write failing pane tests**

Add tests that load four upcoming tracks and three history tracks, navigate
down, assert the second upcoming track is selected, render with `active: true`
and observe selection styling on that row, then assert history rows have no
selection styling. Add a long-queue test showing navigation can reveal later
upcoming rows while the `Previously` section stays pinned.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```sh
mise exec -- bundle exec ruby -Itest test/queued_pane_test.rb
```

Expected: FAIL because QueuedPane has no selection API and its renderer always
passes `selected: false`.

- [ ] **Step 3: Implement QueuedPane integration**

Construct `QueueSelection` from the upcoming source. On `reload!`, replace its
items and refresh history rows. In `display_rows`, reserve the existing pinned
history block first, ask `QueueSelection` for the upcoming viewport, preserve
the existing `Upcoming (count/duration)` header and `+ N more` trailing row, and
ensure the selected upcoming row is included when the upcoming area scrolls.
Pass `active` into row rendering and call `QueueSelection#follow_selection`
with the available upcoming body height.

- [ ] **Step 4: Run focused tests and verify pass**

Run the same focused command. Expected: all existing formatting/duration tests
and new selection tests pass.

---

### Task 3: Delegate TracksPane queue mode to shared selection

**Files:**
- Modify: `lib/rubyplayer/ui/tracks_pane.rb:10-230,300-370`
- Modify: `test/tracks_pane_test.rb`

**Interfaces:**
- `TracksPane#selected_queue_track` continues returning the selected queue
  track only in `:queue` mode.
- `TracksPane#selected_track_index` continues returning the selected visible
  queue position for queue mode and existing row-derived behavior elsewhere.

- [ ] **Step 1: Write regression tests**

Add tests proving queue-mode navigation, page movement, filtering, reload
identity preservation, and queue-order rendering retain current behavior after
delegation. Keep the existing regression that sorting/grouping a folder before
opening the queue cannot reorder queue rows.

- [ ] **Step 2: Run focused tests and verify baseline failure**

Run:

```sh
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb
```

Expected: new delegation-specific assertions fail before integration.

- [ ] **Step 3: Replace queue-mode cursor mechanics**

Instantiate one `QueueSelection` for TracksPane. In `show`, `load_tracks`,
`filter=`, `reload!`, `render`, and `handle_action`, branch only for `@mode ==
:queue`: feed the current filtered queue tracks to `replace`, use its selection
and page size, and keep non-queue modes on existing `@selection/@scroll`
state. Preserve view-state save/restore by recording queue selected identity and
scroll separately. Keep queue sorting/grouping disabled and preserve flat queue
row construction.

- [ ] **Step 4: Run focused tests and verify pass**

Run the same TracksPane command. Expected: all queue and non-queue pane tests
pass.

---

### Task 4: Add visible-pane focus cycling and active rendering

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb:310-325,620-640,900-915,1080-1165`
- Modify: `test/app_rendering_theme_config_test.rb`

**Interfaces:**
- Private `App#focusable_panes` returns `[:library, :tracks]` plus `:queued`
  only when `queued_pane_cols(@screen.cols).positive?`.
- Private `App#normalize_active_pane!` moves a hidden active pane to the next
  eligible visual-order pane, wrapping if no later pane exists.
- `App#dispatch(:cycle_pane)` cycles `focusable_panes` rather than toggling a
  hard-coded pair.

- [ ] **Step 1: Write failing focus/layout tests**

Cover wide-screen Tab sequence `library → tracks → queued → library`, hidden
Queued exclusion when preference is false, width threshold, and top-level
Playback Queue suppression. Set `@active_pane = :queued`, hide it by toggle or
resize, and assert normalization chooses an eligible pane before rendering.
Assert the Queued border title is active only while Queued is focused.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```sh
mise exec -- bundle exec ruby -Itest test/app_rendering_theme_config_test.rb
```

Expected: new focus tests fail because App currently cycles only Library and
Tracks and always draws Queued inactive.

- [ ] **Step 3: Implement focusable-pane calculation and rendering**

Use one visibility predicate for Tab, focus recovery, and rendering. Call
normalization before layout draws. Draw Queued with `active: @active_pane ==
:queued`; pass the same flag to `QueuedPane#render`. Remove the deferred-width
status suffix when toggling the persisted preference; hidden preference state
must not make the pane focusable.

- [ ] **Step 4: Run focused tests and verify pass**

Run the same command. Expected: focus, threshold, and rendering tests pass.

---

### Task 5: Route queue actions and hotkey scope through active Queued

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb:340-405,620-705,875-900`
- Modify: `lib/rubyplayer/keymap.rb:35-80`
- Modify: `test/app_playback_queue_test.rb`
- Modify: `test/keymap_test.rb`
- Modify: `test/bottom_lines_test.rb`

**Interfaces:**
- Private `App#active_queue_track` returns the selected upcoming track from
  TracksPane queue mode or QueuedPane, otherwise nil.
- `App#selected_tracks` returns `[active_queue_track].compact` for active
  Queued and retains existing Library/Tracks behavior elsewhere.
- `App#remove_from_queue` resolves `active_queue_track` by identity against
  `engine.queue_items`, then calls `engine.remove_at(index)`.
- Keymap scope `queued` maps `up/down/pgup/pgdn/shift_up/shift_down/ctrl_u/ctrl_d`
  to the same navigation actions as Tracks.

- [ ] **Step 1: Write failing action/keymap tests**

Add integration tests that focus Queued, move to the second upcoming track,
press `x`, and assert the matching live queue object is removed. Verify `enter`
uses the selected queue track, empty/history-only selections are safe, and Tab
then continues through the visible-pane cycle. Add keymap assertions for every
queued navigation spelling and bottom/help output assertions that Queued scope
is used while active.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

```sh
mise exec -- bundle exec ruby -Itest test/app_playback_queue_test.rb test/keymap_test.rb test/bottom_lines_test.rb
```

Expected: sidebar action tests fail because App routes only Library/Tracks and
the queued keymap scope has no local navigation bindings.

- [ ] **Step 3: Implement active queue routing**

Branch `route_to_pane` for `:queued` and forward navigation to QueuedPane.
Make queue mutation/play-now helpers consult `active_queue_track` instead of
requiring Library’s selected row to be `:queue`. Keep playlist/library actions
out of Queued. Add the `queued` local keymap navigation map and leave global
queue actions (`x`, `enter`, `q`, `n`, undo/redo, playback controls) unchanged.
Ensure queue/history event refreshes preserve selection in both panes.

- [ ] **Step 4: Run focused tests and verify pass**

Run the same focused command. Expected: sidebar editing, keymap, and hotkey
scope tests pass without changing top-level queue behavior.

---

### Task 6: Documentation, full verification, and feature commit

**Files:**
- Modify: `README.md` navigation section if wording still calls Queued
  read-only or omits focusability

- [ ] **Step 1: Update user-facing documentation**

Describe Queued as a focusable sidebar on wide terminals, state that Tab
includes it only while visible, and state that its upcoming rows can be
edited while history rows are informational.

- [ ] **Step 2: Run RuboCop on changed Ruby files**

Run:

```sh
mise exec -- bundle exec rubocop lib/rubyplayer/ui/queue_selection.rb lib/rubyplayer/ui/queued_pane.rb lib/rubyplayer/ui/tracks_pane.rb lib/rubyplayer/ui/app.rb lib/rubyplayer/keymap.rb test/queue_selection_test.rb test/queued_pane_test.rb test/tracks_pane_test.rb test/app_rendering_theme_config_test.rb test/app_playback_queue_test.rb test/keymap_test.rb test/bottom_lines_test.rb
```

Expected: no offenses.

- [ ] **Step 3: Run the full suite**

Run:

```sh
mise exec -- bundle exec rake test
```

Expected: all tests pass with zero failures/errors.

- [ ] **Step 4: Self-review the diff**

Run `git diff --check`, inspect the changed files for duplicated queue
selection logic, verify no hidden pane can remain active, and confirm top-level
Playback Queue rendering still suppresses the sidebar.

- [ ] **Step 5: Commit the implementation**

```sh
git add lib/rubyplayer.rb lib/rubyplayer/ui/queue_selection.rb lib/rubyplayer/ui/queued_pane.rb lib/rubyplayer/ui/tracks_pane.rb lib/rubyplayer/ui/app.rb lib/rubyplayer/keymap.rb README.md test/queue_selection_test.rb test/queued_pane_test.rb test/tracks_pane_test.rb test/app_rendering_theme_config_test.rb test/app_playback_queue_test.rb test/keymap_test.rb test/bottom_lines_test.rb
git commit -m "feat: make queued sidebar editable"
```
