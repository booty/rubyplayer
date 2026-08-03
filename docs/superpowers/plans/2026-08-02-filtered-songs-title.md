# Filtered Songs Pane Title Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show matching count, unfiltered total, and active filter text in every filtered track-containing Songs view.

**Architecture:** Keep title composition inside `UI::TracksPane#title`. Reuse the pane's memoized `filtered_tracks` collection for the matching count and its `@tracks` snapshot for the unfiltered total; do not add Library queries or new title state. Preserve existing truncation after composing the expanded title.

**Tech Stack:** Ruby 4.x, Minitest, RuboCop, existing `TracksPane` and `Track` models.

## Global Constraints

- Effective filter means `@filter.strip` is non-empty.
- Unfiltered total is the current view's loaded `@tracks.size`.
- Filtered title format is `Label · N of M (Filter: 'term')`.
- Apostrophes in displayed filter text are escaped inside the single-quoted label.
- Playlist index and Focus Sounds titles retain current behavior; track-containing views use the expanded format.
- Existing `max_width` truncation remains the final title operation.
- Use `mise exec -- bundle exec ...` for Ruby commands.
- Write failing tests before production changes.

---

### Task 1: Lock filtered title behavior with TracksPane tests

**Files:**
- Modify: `test/tracks_pane_test.rb` near existing title/filter tests

**Interfaces:**
- Consumes: existing `TracksPane#show`, `#filter=`, and `#title` behavior.
- Produces: executable examples for active, empty-result, cleared, quoted, and truncated filters.

- [ ] **Step 1: Write the failing tests**

Add these tests using the existing three-track folder fixture:

```ruby
def test_filtered_title_shows_matching_and_total_counts_and_term
  @pane.show(@folder_row)
  @pane.filter = 'bravo'

  assert_equal "Tracks · 1 of 3 (Filter: 'bravo')", @pane.title
end

def test_filtered_title_shows_zero_matches
  @pane.show(@folder_row)
  @pane.filter = 'missing'

  assert_equal "Tracks · 0 of 3 (Filter: 'missing')", @pane.title
end

def test_clearing_filter_restores_compact_title
  @pane.show(@folder_row)
  @pane.filter = 'bravo'
  @pane.clear_filter

  assert_equal 'Tracks · 3', @pane.title
end

def test_filtered_title_escapes_apostrophes_in_term
  @pane.show(@folder_row)
  @pane.filter = "charlie's"

  assert_equal "Tracks · 0 of 3 (Filter: 'charlie\\'s')", @pane.title
end

def test_filtered_title_preserves_max_width_truncation
  @pane.show(@folder_row, breadcrumb: 'Music / Sega')
  @pane.filter = 'bravo'

  assert_equal '…Sega · 1 of 3 (Filter: \'bravo\')', @pane.title(max_width: 32)
end

def test_focus_title_keeps_existing_filter_count_format
  @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :focus, depth: 0))
  @pane.filter = 'dark'

  assert_equal 'Focus · 1', @pane.title
end

def test_playlist_index_title_keeps_existing_filter_count_format
  @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :playlists, depth: 0))
  @pane.filter = 'missing'

  assert_equal 'Playlists · 0', @pane.title
end
```

Keep expected strings literal. The test names identify the production behavior
each mutation must break.

- [ ] **Step 2: Run the focused tests and verify RED**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb -n '/filtered_title|clearing_filter/'
```

Expected: the new tests fail because `TracksPane#title` currently reports only
the filtered count and does not include the total or filter label. Existing
title tests should remain green.

### Task 2: Implement expanded filtered title

**Files:**
- Modify: `lib/rubyplayer/ui/tracks_pane.rb` in `TracksPane#title`

**Interfaces:**
- Consumes: `@filter`, `filtered_tracks`, `@tracks`, and existing `max_width` argument.
- Produces: unchanged unfiltered title strings and expanded filtered strings.

- [ ] **Step 1: Add focused title formatting**

Build the count portion from the existing label and filtered collection. Only
track-backed modes use the expanded form; `:focus` and `:playlists` keep their
current count-only titles:

```ruby
count = filtered_tracks.size.to_s
if !@filter.strip.empty? && !%i[focus playlists].include?(@mode)
  term = @filter.gsub("'") { "\\'" }
  count = "#{filtered_tracks.size} of #{@tracks.size} (Filter: '#{term}')"
end
text = "#{label} · #{count}"
```

Leave the existing `max_width` truncation branch unchanged and after this
composition. This makes all track-containing modes use the same behavior
without changing filtering, sorting, rows, or database access.

- [ ] **Step 2: Run focused tests and verify GREEN**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb -n '/filtered_title|clearing_filter|title_contains|special_view_title|smart_view|all_songs_view|title_left/'
```

Expected: all selected title tests pass.

### Task 3: Full verification and handoff

**Files:**
- No additional production files.
- Include: `docs/superpowers/plans/2026-08-02-filtered-songs-title.md` in the feature commit.

**Interfaces:**
- Consumes: completed title behavior and regression tests.
- Produces: verified, clean implementation.

- [ ] **Step 1: Run all TracksPane tests**

```bash
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb
```

- [ ] **Step 2: Run RuboCop on changed Ruby files**

```bash
mise exec -- bundle exec rubocop lib/rubyplayer/ui/tracks_pane.rb test/tracks_pane_test.rb
```

Expected: no offenses.

- [ ] **Step 3: Run the full suite and whitespace check**

```bash
mise exec -- bundle exec rake test
git diff --check
```

Expected: zero test failures/errors and no whitespace errors.

- [ ] **Step 4: Commit the feature**

```bash
git add docs/superpowers/plans/2026-08-02-filtered-songs-title.md \
  lib/rubyplayer/ui/tracks_pane.rb test/tracks_pane_test.rb
git commit -m "feat(ui): show filtered song totals"
```
