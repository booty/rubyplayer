# All Songs Library Root Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an expanded-by-default `All Songs` library row that contains every visible folder and displays every present track.

**Architecture:** `LibraryPane` adds a synthetic `:all` navigation row and nests database roots beneath it without changing stored folder relationships. `Library#all_tracks` provides present-track data; `TracksPane` and `App` route `:all` selection and queue actions through that query.

**Tech Stack:** Ruby 4.0.1, Minitest, SQLite3, custom terminal UI

## Global Constraints

- `All Songs` starts expanded for every new `LibraryPane`.
- Only tracks with `missing = 0` appear in `All Songs`.
- Existing special-view order remains unchanged.
- Existing folder selection, nesting, breadcrumbs, removal, sorting, grouping, filtering, and queue behavior remain unchanged.
- No schema, configuration, scanner, or persisted-data changes.
- Run Ruby commands through `mise exec -- bundle exec`.
- Follow strict red-green-refactor: production code only after relevant failing tests.
- One implementation commit for this feature.

---

### Task 1: Add All Songs navigation and data flow

**Files:**
- Modify: `test/library_test.rb`
- Modify: `test/library_pane_test.rb`
- Modify: `test/tracks_pane_test.rb`
- Modify: `test/app_test.rb`
- Modify: `lib/rubyplayer/library.rb`
- Modify: `lib/rubyplayer/ui/library_pane.rb`
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer/ui/app.rb`

**Interfaces:**
- Produces: `Library#all_tracks -> Array<RubyPlayer::Track>` containing every `missing = 0` track ordered by `physical_path, subtune_index`.
- Produces: `LibraryPane::Row` with `kind: :all`, `folder: nil`, and `depth: 0`.
- Consumes: existing `Library#roots`, `Library#children_of`, `TracksPane#show`, and App queue-action flow.

- [ ] **Step 1: Add failing Library query test**

Add to `test/library_test.rb`:

```ruby
def test_all_tracks_excludes_missing_and_orders_by_path_and_subtune
  add_track("/m/sega/b.vgm", title: "B")
  add_track("/m/sega/a.nsf", subtune: 1, title: "A2")
  add_track("/m/sega/a.nsf", subtune: 0, title: "A1")
  missing_id = add_track("/m/sega/gone.vgm", title: "Gone")
  @lib.mark_missing(track_ids: [missing_id], folder_ids: [])

  tracks = @lib.all_tracks

  assert_equal %w[A1 A2 B], tracks.map(&:title)
end
```

- [ ] **Step 2: Run Library test and verify red**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/library_test.rb
```

Expected: error because `RubyPlayer::Library` has no `all_tracks` method.

- [ ] **Step 3: Add failing LibraryPane hierarchy tests and update affected expectations**

Replace `test_specials_then_visible_roots_only` in `test/library_pane_test.rb`:

```ruby
def test_specials_then_all_songs_and_visible_roots
  assert_equal %i[queue history favorites focus recent unrated missing failed most_played all folder], kinds
  assert_equal :all, @pane.rows[9].kind
  assert_equal "Music", @pane.rows[10].folder["name"] # Empty (0 tracks) hidden
  assert_equal 1, @pane.rows[10].depth
end
```

Add:

```ruby
def test_all_songs_starts_expanded_and_can_collapse_and_reexpand
  9.times { @pane.handle_action(:nav_down) }

  assert_equal :all, @pane.selected.kind
  assert_equal ["Music"], @pane.rows.select { |row| row.kind == :folder }.map { |row| row.folder["name"] }

  @pane.handle_action(:collapse)
  assert_empty @pane.rows.select { |row| row.kind == :folder }

  @pane.handle_action(:expand)
  assert_equal ["Music"], @pane.rows.select { |row| row.kind == :folder }.map { |row| row.folder["name"] }
end

def test_all_songs_breadcrumb_and_rendered_label
  row = @pane.rows.find { |candidate| candidate.kind == :all }

  assert_equal "All Songs", @pane.breadcrumb_for(row)
  screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 11, cols: 40)
  @pane.render(screen, x: 0, y: 0, w: 40, h: 11, active: true,
               theme: RubyPlayer::Theme::DEFAULT)
  assert_includes screen.flush, "All Songs"
end
```

Adjust existing folder indexes and counts:

```ruby
# Select Music after fixed views and All Songs.
10.times { @pane.handle_action(:nav_down) }

# Music collapse leaves fixed views, All Songs, and Music.
assert_equal 11, @pane.rows.size
```

Update any ten-row render used to assert folder text to eleven rows so `Music`
remains visible beneath `All Songs`.

- [ ] **Step 4: Add failing TracksPane All Songs test**

Add to `test/tracks_pane_test.rb`:

```ruby
def test_all_songs_view_loads_present_tracks_and_uses_dynamic_title
  bravo = @lib.all_tracks.find { |track| track.title == "Bravo" }
  @lib.mark_missing(track_ids: [bravo.id], folder_ids: [])

  @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :all, depth: 0))

  assert_equal %w[Alpha Charlie], titles.sort
  assert_equal "All Songs · 2", @pane.title
end
```

This test depends on Step 3's planned query but still fails because `TracksPane`
does not load or title `:all` mode.

- [ ] **Step 5: Add failing App integration tests**

Add to `test/app_test.rb`:

```ruby
def test_selecting_all_songs_displays_every_present_track
  select_tracks_for(:all)

  assert_equal 2, @app.tracks_pane.visible_tracks.size
  assert_equal "All Songs · 2", @app.tracks_pane.title
end

def test_enqueue_all_songs_adds_every_present_track
  select_library_kind(:all)

  @app.handle_key("n")

  assert_equal 2, @app.engine.queue_items.size
end
```

- [ ] **Step 6: Run UI and App tests and verify red**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/library_pane_test.rb
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb
mise exec -- bundle exec ruby -Itest test/app_test.rb
```

Expected failures:

- `LibraryPane` lacks `:all` row and nesting.
- `TracksPane` renders `Tracks · 0` for `:all`.
- App cannot find `:all` row or enqueue its tracks.

- [ ] **Step 7: Implement present-track query**

Add to `lib/rubyplayer/library.rb` beside `tracks_under`:

```ruby
def all_tracks
  query_tracks("missing = 0 ORDER BY physical_path, subtune_index")
end
```

- [ ] **Step 8: Implement expanded synthetic LibraryPane row**

In `LibraryPane#initialize`, seed expansion state:

```ruby
@expanded = { all: true }
```

In `LibraryPane#rebuild!`, append `All Songs` and nest roots:

```ruby
@rows = SPECIALS.map { |kind, _| Row.new(kind: kind, depth: 0) }
@rows << Row.new(kind: :all, depth: 0)
@library.roots.each { |folder| append_folder(folder, 1, []) } if @expanded[:all]
```

In `LibraryPane#breadcrumb_for`, recognize synthetic row before special lookup:

```ruby
return "All Songs" if row.kind == :all
return SPECIALS.to_h.fetch(row.kind) unless row.kind == :folder
```

Replace `toggle_expand` with:

```ruby
def toggle_expand(open)
  row = selected
  case row&.kind
  when :all
    @expanded[:all] = open
  when :folder
    @expanded[row.folder["id"]] = open
  else
    return
  end
  rebuild!
end
```

Add `:all` rendering to `label_for`:

```ruby
when :all then ["#{@glyphs['dir']} All Songs", ""]
```

- [ ] **Step 9: Implement TracksPane All Songs mode**

Add to `TracksPane#title`:

```ruby
when :all then "All Songs"
```

Add to `TracksPane#load_tracks`:

```ruby
when :all then @library.all_tracks
```

- [ ] **Step 10: Implement App All Songs queue selection**

Add to Library-pane branch in `App#selected_tracks`:

```ruby
when :all then @library.all_tracks
```

No `show_selected_tracks` change is needed: existing row dispatch already sends
synthetic row to `TracksPane#show`. No removal change is needed: existing
`:folder` guard rejects `:all`.

- [ ] **Step 11: Run focused tests and verify green**

Run:

```bash
mise exec -- bundle exec ruby -Itest test/library_test.rb
mise exec -- bundle exec ruby -Itest test/library_pane_test.rb
mise exec -- bundle exec ruby -Itest test/tracks_pane_test.rb
mise exec -- bundle exec ruby -Itest test/app_test.rb
```

Expected: all four files pass with zero failures and zero errors.

- [ ] **Step 12: Run full suite and inspect diff**

Run:

```bash
mise exec -- bundle exec rake test
git diff --check
git status --short
```

Expected: full suite passes; `git diff --check` prints nothing; status lists only
planned implementation and plan files.

- [ ] **Step 13: Commit implementation**

```bash
git add lib/rubyplayer/library.rb lib/rubyplayer/ui/library_pane.rb \
  lib/rubyplayer/ui/tracks_pane.rb lib/rubyplayer/ui/app.rb \
  test/library_test.rb test/library_pane_test.rb test/tracks_pane_test.rb \
  test/app_test.rb docs/superpowers/plans/2026-07-16-all-songs-library-root.md
git commit -m "feat(ui): add All Songs library root"
```
