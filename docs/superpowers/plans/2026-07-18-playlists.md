# User-Defined Playlists Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** User-curated playlists stored in the library DB, surfaced in the sidebar, with an add-via-modal flow, reorderable tracks, and duplicate/rename/delete operations.

**Architecture:** Two new SQLite tables (`playlists`, `playlist_tracks`) behind new `Library` methods; a fixed `:playlists` sidebar view whose children are dynamic playlist rows; `TracksPane` gains a playlist-list mode and a never-sorted playlist-tracks mode; `App` gains three modal states (add-to-playlist, name prompt, delete confirm) following the existing input-capture pattern.

**Tech Stack:** Ruby 4.0.1 (via mise), sqlite3 gem, minitest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-18-playlists-design.md` — read it before starting.

## Global Constraints

- Ruby comes from mise; `mise exec` is unreliable in this shell. Every test/commit command must first run:
  `export PATH="$HOME/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"` and `set -o pipefail` (piping test output otherwise masks rake's exit status).
- TDD strictly: write the failing test, watch it fail, minimal code to green.
- Full suite (`bundle exec rake test`, ~2s) green before every commit. One commit per task.
- Comments explain **why**, not what. No hardcoded magic numbers — expose in `DEFAULTS` in `lib/rubyplayer/config.rb`.
- In `test/app_test.rb`, new test methods MUST go **above** the `private` keyword near the bottom — Minitest silently skips test methods defined after `private` (this has bitten before).
- The app cannot run headlessly; verify only through the test suite.
- Playlist tracks and the queue share a load-bearing rule: **row index == position; never sort or group those views.**

---

### Task 1: Schema v2 + playlist CRUD in Library

**Files:**
- Modify: `lib/rubyplayer/database.rb` (SCHEMA_VERSION, SCHEMA)
- Modify: `lib/rubyplayer/library.rb`
- Test: `test/library_test.rb`

**Interfaces:**
- Consumes: existing `Database#write/#read`, `Track.from_row`.
- Produces (later tasks depend on these exact signatures):
  - `Library::PlaylistError < StandardError`, `Library::PlaylistNameTaken < PlaylistError`
  - `Library#playlists(sort: :recency)` → array of row hashes with `"id"`, `"name"`, `"track_count"` (visible tracks only), `"updated_at"`. `sort:` is `:recency` (`updated_at DESC`) or `:alpha` (`name COLLATE NOCASE`).
  - `Library#create_playlist(name)` → Integer id; raises `PlaylistNameTaken` on duplicate name (case-insensitive).
  - `Library#rename_playlist(id, name)` → raises `PlaylistNameTaken` on collision.
  - `Library#delete_playlist(id)` → hard delete, entries cascade.
  - `Library#add_to_playlist(id, track_id)` → appends at end; raises `PlaylistError` if the track row no longer exists.
  - `Library#playlist_contains?(id, track_id)` → boolean.

- [ ] **Step 1: Write the failing tests**

Append to `test/library_test.rb` (inside `class LibraryTest`, anywhere above the end of the class):

```ruby
  # ---- playlists (user curation; see docs/superpowers/specs/2026-07-18-playlists-design.md) ----

  def test_create_playlist_and_list
    id = @lib.create_playlist("Chill VGM")
    assert_kind_of Integer, id
    lists = @lib.playlists
    assert_equal ["Chill VGM"], lists.map { |p| p["name"] }
    assert_equal 0, lists.first["track_count"]
  end

  def test_create_playlist_rejects_duplicate_name_case_insensitively
    @lib.create_playlist("Chill")
    assert_raises(RubyPlayer::Library::PlaylistNameTaken) { @lib.create_playlist("chill") }
  end

  def test_playlists_sorts_by_recency_default_and_alpha_on_request
    a = @lib.create_playlist("Alpha")
    b = @lib.create_playlist("Beta")
    # Adding a track bumps updated_at, so Alpha becomes most recent.
    t = add_track("/m/sega/a.vgm")
    @lib.add_to_playlist(a, t)
    assert_equal %w[Alpha Beta], @lib.playlists(sort: :recency).map { |p| p["name"] }
    assert_equal %w[Alpha Beta], @lib.playlists(sort: :alpha).map { |p| p["name"] }
    @lib.add_to_playlist(b, t)
    assert_equal %w[Beta Alpha], @lib.playlists(sort: :recency).map { |p| p["name"] }
  end

  def test_rename_playlist_bumps_updated_at_and_rejects_taken_names
    a = @lib.create_playlist("Old")
    @lib.create_playlist("Taken")
    assert_raises(RubyPlayer::Library::PlaylistNameTaken) { @lib.rename_playlist(a, "taken") }
    @lib.rename_playlist(a, "New")
    assert_equal %w[New Taken], @lib.playlists(sort: :alpha).map { |p| p["name"] }
  end

  def test_add_to_playlist_and_contains
    id = @lib.create_playlist("P")
    t = add_track("/m/sega/a.vgm")
    refute @lib.playlist_contains?(id, t)
    @lib.add_to_playlist(id, t)
    assert @lib.playlist_contains?(id, t)
    assert_equal 1, @lib.playlists.first["track_count"]
  end

  def test_add_to_playlist_allows_duplicates
    id = @lib.create_playlist("P")
    t = add_track("/m/sega/a.vgm")
    @lib.add_to_playlist(id, t)
    @lib.add_to_playlist(id, t)
    assert_equal 2, @lib.playlists.first["track_count"]
  end

  def test_add_to_playlist_raises_for_vanished_track
    id = @lib.create_playlist("P")
    assert_raises(RubyPlayer::Library::PlaylistError) { @lib.add_to_playlist(id, 999_999) }
  end

  def test_delete_playlist_is_hard_and_cascades_entries
    id = @lib.create_playlist("P")
    t = add_track("/m/sega/a.vgm")
    @lib.add_to_playlist(id, t)
    @lib.delete_playlist(id)
    assert_empty @lib.playlists
    # Entries must be gone too, or a future playlist reusing the id would inherit them.
    count = @db.read { |s| s.get_first_value("SELECT COUNT(*) FROM playlist_tracks") }
    assert_equal 0, count
  end

  def test_playlist_track_count_excludes_missing_tracks
    id = @lib.create_playlist("P")
    t = add_track("/m/sega/a.vgm")
    @lib.add_to_playlist(id, t)
    @lib.mark_missing(track_ids: [t], folder_ids: [])
    assert_equal 0, @lib.playlists.first["track_count"]
  end
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
export PATH="$HOME/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"
set -o pipefail
bundle exec ruby -Itest test/library_test.rb
```
Expected: errors — `no such table: playlists` / `undefined method 'create_playlist'`.

- [ ] **Step 3: Implement schema + methods**

In `lib/rubyplayer/database.rb`, bump `SCHEMA_VERSION = 2` and append to the `SCHEMA` heredoc (before the `CREATE INDEX` block):

```sql
      CREATE TABLE playlists (
        id INTEGER PRIMARY KEY,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL       -- bumped on any content/name change; recency sort key
      );

      CREATE TABLE playlist_tracks (
        playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        track_id INTEGER NOT NULL REFERENCES tracks(id),
        position INTEGER NOT NULL,
        -- Position integrity as a DB constraint: a buggy renumber fails loudly
        -- in tests instead of silently corrupting playlist order.
        PRIMARY KEY (playlist_id, position)
      );
```

And add with the other indexes: `CREATE INDEX idx_playlist_tracks_track ON playlist_tracks(track_id);`

In `lib/rubyplayer/library.rb`, inside `class Library` (near the top, after `def initialize`):

```ruby
    # Playlists are user curation, not disk state: the library's soft-delete
    # philosophy does not apply, so deletes are hard and cascade.
    PlaylistError = Class.new(StandardError)
    PlaylistNameTaken = Class.new(PlaylistError)

    def playlists(sort: :recency)
      order = sort == :alpha ? "name COLLATE NOCASE" : "updated_at DESC"
      @db.read do |s|
        s.execute(<<~SQL)
          SELECT p.*, (
            SELECT COUNT(*) FROM playlist_tracks pt
            JOIN tracks t ON t.id = pt.track_id
            WHERE pt.playlist_id = p.id AND t.missing = 0
          ) AS track_count
          FROM playlists p ORDER BY #{order}
        SQL
      end
    end

    def create_playlist(name)
      now = Time.now.utc.iso8601(6)
      @db.write do |s|
        s.execute("INSERT INTO playlists (name, created_at, updated_at) VALUES (?, ?, ?)",
                  [name, now, now])
        s.get_first_value("SELECT id FROM playlists WHERE name = ?", [name])
      end
    rescue SQLite3::ConstraintException
      raise PlaylistNameTaken, "A playlist named \"#{name}\" already exists"
    end

    def rename_playlist(id, name)
      @db.write do |s|
        s.execute("UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?",
                  [name, Time.now.utc.iso8601(6), id])
      end
    rescue SQLite3::ConstraintException
      raise PlaylistNameTaken, "A playlist named \"#{name}\" already exists"
    end

    def delete_playlist(id)
      @db.write { |s| s.execute("DELETE FROM playlists WHERE id = ?", [id]) }
    end

    def add_to_playlist(id, track_id)
      @db.write do |s|
        pos = s.get_first_value(
          "SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_tracks WHERE playlist_id = ?", [id]
        )
        s.execute("INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                  [id, track_id, pos])
        s.execute("UPDATE playlists SET updated_at = ? WHERE id = ?",
                  [Time.now.utc.iso8601(6), id])
      end
    rescue SQLite3::ConstraintException
      # FK failure: the track was hard-purged while the add modal was open.
      raise PlaylistError, "Track is no longer in the library"
    end

    def playlist_contains?(id, track_id)
      !!@db.read do |s|
        s.get_first_value(
          "SELECT 1 FROM playlist_tracks WHERE playlist_id = ? AND track_id = ? LIMIT 1",
          [id, track_id]
        )
      end
    end
```

- [ ] **Step 4: Run test file, then full suite**

```bash
bundle exec ruby -Itest test/library_test.rb
bundle exec rake test
```
Expected: all PASS. Note: the version bump means any developer DB rebuilds on next launch (backed up first) — expected per CLAUDE.md.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/database.rb lib/rubyplayer/library.rb test/library_test.rb
git commit -m "feat(playlists): schema v2 with playlists tables and Library CRUD"
```

---

### Task 2: Playlist entries — tracks query, move, remove, duplicate, purge cascade

**Files:**
- Modify: `lib/rubyplayer/library.rb`
- Test: `test/library_test.rb`

**Interfaces:**
- Consumes: Task 1's tables and `PlaylistError`.
- Produces:
  - `Library#playlist_tracks(id)` → `[Track]`, visible (missing = 0) only, position order.
  - `Library#move_playlist_entry(id, visible_index, delta)` → new visible index Integer, or nil if out of range. `delta` is +1/-1. Swaps with the visible neighbor; hidden (missing) entries keep positions.
  - `Library#remove_playlist_entry(id, visible_index)` → removed track_id or nil. Renumbers all remaining entries contiguously.
  - `Library#duplicate_playlist(id, name)` → new id; copies ALL entries including hidden ones; raises `PlaylistNameTaken`.
  - `Library#purge_missing_tracks!` also deletes the purged tracks' playlist entries.

- [ ] **Step 1: Write the failing tests**

Append to `test/library_test.rb`:

```ruby
  def playlist_with_tracks(names)
    id = @lib.create_playlist("P")
    ids = names.map { |n| add_track("/m/sega/#{n}.vgm", title: n) }
    ids.each { |t| @lib.add_to_playlist(id, t) }
    [id, ids]
  end

  def test_playlist_tracks_in_position_order_hiding_missing
    id, ids = playlist_with_tracks(%w[a b c])
    assert_equal %w[a b c], @lib.playlist_tracks(id).map(&:title)
    @lib.mark_missing(track_ids: [ids[1]], folder_ids: [])
    assert_equal %w[a c], @lib.playlist_tracks(id).map(&:title)
  end

  def test_hidden_entry_reappears_at_its_position_when_restored
    id, ids = playlist_with_tracks(%w[a b c])
    @lib.mark_missing(track_ids: [ids[1]], folder_ids: [])
    # Rescan restoring the file clears missing (upsert_track sets missing=0).
    add_track("/m/sega/b.vgm", title: "b")
    assert_equal %w[a b c], @lib.playlist_tracks(id).map(&:title)
  end

  def test_move_playlist_entry_swaps_visible_neighbors
    id, = playlist_with_tracks(%w[a b c])
    assert_equal 2, @lib.move_playlist_entry(id, 1, 1) # b down -> a c b
    assert_equal %w[a c b], @lib.playlist_tracks(id).map(&:title)
    assert_equal 0, @lib.move_playlist_entry(id, 1, -1) # c up -> c a b
    assert_equal %w[c a b], @lib.playlist_tracks(id).map(&:title)
  end

  def test_move_playlist_entry_skips_over_hidden_entries
    id, ids = playlist_with_tracks(%w[a b c])
    @lib.mark_missing(track_ids: [ids[1]], folder_ids: [])
    # Visible list is [a c]; moving a down must swap with c, not hidden b.
    @lib.move_playlist_entry(id, 0, 1)
    assert_equal %w[c a], @lib.playlist_tracks(id).map(&:title)
    # b restored: it kept its middle position, order is now c b a.
    add_track("/m/sega/b.vgm", title: "b")
    assert_equal %w[c b a], @lib.playlist_tracks(id).map(&:title)
  end

  def test_move_playlist_entry_out_of_range_is_nil_noop
    id, = playlist_with_tracks(%w[a b])
    assert_nil @lib.move_playlist_entry(id, 0, -1)
    assert_nil @lib.move_playlist_entry(id, 1, 1)
    assert_equal %w[a b], @lib.playlist_tracks(id).map(&:title)
  end

  def test_remove_playlist_entry_renumbers_contiguously
    id, ids = playlist_with_tracks(%w[a b c])
    assert_equal ids[1], @lib.remove_playlist_entry(id, 1)
    assert_equal %w[a c], @lib.playlist_tracks(id).map(&:title)
    positions = @db.read do |s|
      s.execute("SELECT position FROM playlist_tracks WHERE playlist_id = ? ORDER BY position",
                [id]).map { |r| r["position"] }
    end
    assert_equal [0, 1], positions
  end

  def test_duplicate_playlist_copies_all_entries_including_hidden
    id, ids = playlist_with_tracks(%w[a b])
    @lib.mark_missing(track_ids: [ids[0]], folder_ids: [])
    copy = @lib.duplicate_playlist(id, "P copy")
    assert_equal %w[b], @lib.playlist_tracks(copy).map(&:title)
    add_track("/m/sega/a.vgm", title: "a")
    assert_equal %w[a b], @lib.playlist_tracks(copy).map(&:title)
  end

  def test_purge_missing_tracks_removes_playlist_entries
    id, ids = playlist_with_tracks(%w[a b])
    @lib.mark_missing(track_ids: [ids[0]], folder_ids: [])
    @lib.purge_missing_tracks!([ids[0]])
    assert_equal %w[b], @lib.playlist_tracks(id).map(&:title)
    add_track("/m/sega/a.vgm", title: "a") # restore file: entry must NOT come back
    assert_equal %w[b], @lib.playlist_tracks(id).map(&:title)
  end
```

- [ ] **Step 2: Run, verify failures**

```bash
bundle exec ruby -Itest test/library_test.rb
```
Expected: `undefined method 'playlist_tracks'` etc. (`test_purge...` fails on FK constraint or leftover entry).

- [ ] **Step 3: Implement**

Add to `lib/rubyplayer/library.rb` (below Task 1's methods):

```ruby
    def playlist_tracks(id)
      rows = @db.read do |s|
        s.execute(<<~SQL, [id])
          SELECT t.* FROM playlist_tracks pt
          JOIN tracks t ON t.id = pt.track_id
          WHERE pt.playlist_id = ? AND t.missing = 0
          ORDER BY pt.position
        SQL
      end
      rows.map { |r| Track.from_row(r) }
    end

    # UI move/remove address the row the user SEES. Missing entries are hidden
    # but keep their positions, so the visible index is re-resolved to a real
    # position inside the write transaction — same stale-target discipline as
    # purge_missing_tracks! (the missing-set can shift while UI state is held).
    def move_playlist_entry(id, visible_index, delta)
      @db.write do |s|
        visible = visible_positions(s, id)
        target = visible_index + delta
        next nil unless visible_index.between?(0, visible.size - 1) &&
                        target.between?(0, visible.size - 1)

        a = visible[visible_index]
        b = visible[target]
        # Three-step swap dodges the (playlist_id, position) primary key.
        s.execute("UPDATE playlist_tracks SET position = -1 WHERE playlist_id = ? AND position = ?", [id, a])
        s.execute("UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND position = ?", [a, id, b])
        s.execute("UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND position = -1", [b, id])
        s.execute("UPDATE playlists SET updated_at = ? WHERE id = ?", [Time.now.utc.iso8601(6), id])
        target
      end
    end

    def remove_playlist_entry(id, visible_index)
      @db.write do |s|
        visible = visible_positions(s, id)
        position = visible[visible_index]
        next nil unless position && visible_index >= 0

        track_id = s.get_first_value(
          "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? AND position = ?",
          [id, position]
        )
        s.execute("DELETE FROM playlist_tracks WHERE playlist_id = ? AND position = ?", [id, position])
        # Renumber everything (hidden entries included) contiguously; ascending
        # order only ever moves a row into a just-freed slot, so the PK holds.
        remaining = s.execute(
          "SELECT position FROM playlist_tracks WHERE playlist_id = ? ORDER BY position", [id]
        ).map { |r| r["position"] }
        remaining.each_with_index do |pos, i|
          next if pos == i
          s.execute("UPDATE playlist_tracks SET position = ? WHERE playlist_id = ? AND position = ?",
                    [i, id, pos])
        end
        s.execute("UPDATE playlists SET updated_at = ? WHERE id = ?", [Time.now.utc.iso8601(6), id])
        track_id
      end
    end

    # Hidden-missing entries are copied too: they reappear in the copy when a
    # rescan restores the files, same as in the original.
    def duplicate_playlist(id, name)
      now = Time.now.utc.iso8601(6)
      @db.write do |s|
        s.execute("INSERT INTO playlists (name, created_at, updated_at) VALUES (?, ?, ?)",
                  [name, now, now])
        new_id = s.get_first_value("SELECT id FROM playlists WHERE name = ?", [name])
        s.execute(<<~SQL, [new_id, id])
          INSERT INTO playlist_tracks (playlist_id, track_id, position)
          SELECT ?, track_id, position FROM playlist_tracks WHERE playlist_id = ?
        SQL
        new_id
      end
    rescue SQLite3::ConstraintException
      raise PlaylistNameTaken, "A playlist named \"#{name}\" already exists"
    end
```

Add the private helper (below the existing `visible_folders` private method):

```ruby
    def visible_positions(s, playlist_id)
      s.execute(<<~SQL, [playlist_id]).map { |r| r["position"] }
        SELECT pt.position FROM playlist_tracks pt
        JOIN tracks t ON t.id = pt.track_id
        WHERE pt.playlist_id = ? AND t.missing = 0
        ORDER BY pt.position
      SQL
    end
```

**Note:** `visible_positions` must stay ABOVE `private` if called from `@db.write` blocks in public methods — it's called via `self`, so `private` is fine in Ruby ≥2.7. Place it under `private` with the other helpers.

In `purge_missing_tracks!`, add the playlist-entry delete alongside the other child-table deletes (order matters — before the `tracks` DELETE, or the FK blocks it):

```ruby
        db.execute("DELETE FROM playback_history WHERE track_id IN (#{actual_placeholders})", actual)
        db.execute("DELETE FROM track_metadata WHERE track_id IN (#{actual_placeholders})", actual)
        db.execute("DELETE FROM playlist_tracks WHERE track_id IN (#{actual_placeholders})", actual)
        db.execute("DELETE FROM tracks WHERE id IN (#{actual_placeholders})", actual)
```

- [ ] **Step 4: Run test file + full suite**

```bash
bundle exec ruby -Itest test/library_test.rb
bundle exec rake test
```
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/library.rb test/library_test.rb
git commit -m "feat(playlists): entry queries, move/remove with visible-index translation, duplicate, purge cascade"
```

---

### Task 3: KeyDecoder ctrl-arrow sequences

**Files:**
- Modify: `lib/rubyplayer/ui/key_decoder.rb:8-11`
- Test: `test/key_decoder_test.rb`

**Interfaces:**
- Produces: decoded key names `"ctrl_up"` / `"ctrl_down"` for `\e[1;5A` / `\e[1;5B` (later tasks bind them to move actions).

- [ ] **Step 1: Write the failing test**

Append to the test class in `test/key_decoder_test.rb`:

```ruby
  def test_decodes_ctrl_arrows
    assert_equal ["ctrl_up"], RubyPlayer::UI::KeyDecoder.decode("\e[1;5A")
    assert_equal ["ctrl_down"], RubyPlayer::UI::KeyDecoder.decode("\e[1;5B")
  end
```

- [ ] **Step 2: Run, verify failure**

```bash
bundle exec ruby -Itest test/key_decoder_test.rb
```
Expected: FAIL — unknown sequences are dropped, `[]` returned.

- [ ] **Step 3: Implement**

In `ESC_SEQS`, extend the modifier line:

```ruby
                   # xterm-style modifier encoding: "1;2" = shift, "1;5" = ctrl
                   "[1;2A" => "shift_up", "[1;2B" => "shift_down",
                   "[1;5A" => "ctrl_up", "[1;5B" => "ctrl_down" }.freeze
```

- [ ] **Step 4: Run test file + full suite** — expected PASS.

```bash
bundle exec ruby -Itest test/key_decoder_test.rb
bundle exec rake test
```

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/key_decoder.rb test/key_decoder_test.rb
git commit -m "feat(keys): decode ctrl-arrow escape sequences"
```

---

### Task 4: Keymap bindings, hotkey labels, config default

**Files:**
- Modify: `lib/rubyplayer/keymap.rb`
- Modify: `lib/rubyplayer/ui/bottom_lines.rb:82-96` (LABELS)
- Modify: `lib/rubyplayer/config.rb` (DEFAULTS ui)
- Test: `test/keymap_test.rb`

**Interfaces:**
- Produces action symbols later tasks dispatch on: `:add_to_playlist` (global `l`), `:duplicate_playlist` (library `c`), `:rename_playlist` (library `r`), `:move_entry_up`/`:move_entry_down` (tracks `ctrl_up`/`ctrl_down`).
- Produces config key `@config["ui", "playlist_recent_count"]` → 3 (recent section size in the add modal).

- [ ] **Step 1: Write the failing test**

Append to the test class in `test/keymap_test.rb`:

```ruby
  def test_playlist_bindings
    map = RubyPlayer::Keymap.new({})
    assert_equal :add_to_playlist, map.action_for("l", pane: :tracks)
    assert_equal :add_to_playlist, map.action_for("l", pane: :library)
    assert_equal :duplicate_playlist, map.action_for("c", pane: :library)
    assert_equal :rename_playlist, map.action_for("r", pane: :library)
    assert_equal :move_entry_up, map.action_for("ctrl_up", pane: :tracks)
    assert_equal :move_entry_down, map.action_for("ctrl_down", pane: :tracks)
  end
```

- [ ] **Step 2: Run, verify failure** — `bundle exec ruby -Itest test/keymap_test.rb` → FAIL (nil actions).

- [ ] **Step 3: Implement**

`keymap.rb` — add to `"global"` (after the `"o"` line):

```ruby
        # "l" for "list": opens the add-to-playlist modal on the highlighted track.
        "l" => "add_to_playlist",
```

Add to `"library"` (after the `"x"` line):

```ruby
        # Playlist management lives pane-local: c/r only make sense on a
        # playlist child row, and keeping them out of "global" leaves the
        # letters free for future tracks-pane bindings.
        "c" => "duplicate_playlist",
        "r" => "rename_playlist",
```

Add to `"tracks"` (after the `"i"` line):

```ruby
        # Reorder is ctrl+arrows (not letters): it repeats rapidly when held,
        # and arrow keys already mean "vertical movement" here.
        "ctrl_up" => "move_entry_up", "ctrl_down" => "move_entry_down",
```

`bottom_lines.rb` LABELS — add entries:

```ruby
        add_to_playlist: "playlist+", duplicate_playlist: "dup playlist",
        rename_playlist: "rename", move_entry_up: nil, move_entry_down: nil,
```

(`nil` label = hidden from the compact hotkey line, still listed in the help modal — same treatment as nav keys.)

`config.rb` DEFAULTS `"ui"` — add after `"art_accent"`:

```ruby
      # Direct-pick rows at the top of the add-to-playlist modal.
      "playlist_recent_count" => 3,
```

- [ ] **Step 4: Run test file + full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/keymap.rb lib/rubyplayer/ui/bottom_lines.rb lib/rubyplayer/config.rb test/keymap_test.rb
git commit -m "feat(playlists): key bindings, hotkey labels, recent-count config"
```

---

### Task 5: Sidebar — Playlists parent view + dynamic child rows

**Files:**
- Modify: `lib/rubyplayer/ui/views.rb` (add `:playlists` fixed view)
- Modify: `lib/rubyplayer/ui/library_pane.rb`
- Test: `test/library_pane_test.rb`

**Interfaces:**
- Consumes: `Library#playlists` (Task 1).
- Produces:
  - `Views::ALL[:playlists]` — label "Playlists", glyph "playlist", nil query (so `Views.query(:playlists, lib)` → `[]`, keeping "enqueue the sidebar row itself" a no-op for the parent).
  - `LibraryPane::Row` gains a `:playlist` member; rows of kind `:playlist` carry the playlist hash there, `depth: 1`.
  - `LibraryPane#select_playlist(id)` → expands the node, rebuilds, moves selection to that child; returns true/false.
  - `LibraryPane#breadcrumb_for` returns `"Playlists / <name>"` for child rows.

- [ ] **Step 1: Write the failing tests**

Look at `test/library_pane_test.rb`'s existing setup first (it builds a Library with a temp DB — reuse its helpers). Append tests:

```ruby
  def test_playlists_parent_sits_above_all_songs_with_children_expanded
    @lib.create_playlist("Battle Themes")
    @lib.create_playlist("Chill")
    pane = RubyPlayer::UI::LibraryPane.new(library: @lib, glyphs: RubyPlayer::DEFAULTS["glyphs"])
    pane.rebuild!
    kinds = pane.rows.map(&:kind)
    playlists_at = kinds.index(:playlists)
    all_at = kinds.index(:all)
    refute_nil playlists_at
    # Children (recency order) directly beneath the parent, before All Songs.
    assert_equal %i[playlist playlist], kinds[(playlists_at + 1), 2]
    assert_operator playlists_at, :<, all_at
    child = pane.rows[playlists_at + 1]
    assert_equal 1, child.depth
    assert_equal "Chill", child.playlist["name"]
    assert_equal "Playlists / Chill", pane.breadcrumb_for(child)
  end

  def test_playlists_node_collapses
    @lib.create_playlist("P")
    pane = RubyPlayer::UI::LibraryPane.new(library: @lib, glyphs: RubyPlayer::DEFAULTS["glyphs"])
    pane.rebuild!
    pane.instance_variable_set(:@selection, pane.rows.index { |r| r.kind == :playlists })
    pane.handle_action(:collapse)
    refute_includes pane.rows.map(&:kind), :playlist
    pane.handle_action(:expand)
    assert_includes pane.rows.map(&:kind), :playlist
  end

  def test_select_playlist_expands_and_moves_selection
    id = @lib.create_playlist("P")
    pane = RubyPlayer::UI::LibraryPane.new(library: @lib, glyphs: RubyPlayer::DEFAULTS["glyphs"])
    pane.rebuild!
    pane.handle_action(:collapse) if pane.selected&.kind == :playlists
    assert pane.select_playlist(id)
    assert_equal :playlist, pane.selected.kind
    assert_equal id, pane.selected.playlist["id"]
  end
```

(Adapt `@lib` construction to the file's existing setup helper names — the file already builds a Library; match its idiom.)

- [ ] **Step 2: Run, verify failure** — `bundle exec ruby -Itest test/library_pane_test.rb` → FAIL (`:playlists` absent, no `playlist` struct member).

- [ ] **Step 3: Implement**

`views.rb` — insert into `ALL` between `most_played:` and `all:`:

```ruby
        # nil query: the parent row is a container — enqueueing it wholesale
        # is a no-op (children carry the tracks), same rule as queue/history.
        playlists: View.new(label: "Playlists", glyph: "playlist"),
```

`library_pane.rb`:

```ruby
      Row = Struct.new(:kind, :folder, :playlist, :depth, keyword_init: true)
```

`initialize`: `@expanded = { all: true, playlists: true }`

`rebuild!` becomes:

```ruby
      def rebuild!
        @breadcrumbs = {}
        @rows = []
        # Views::ALL's insertion order is the sidebar order; :all is last so
        # the folder tree (its expanded children) renders directly beneath it.
        # Playlist children hang off :playlists the same way.
        Views::ALL.keys.each do |kind|
          @rows << Row.new(kind: kind, depth: 0)
          next unless kind == :playlists && @expanded[:playlists]

          @library.playlists.each do |playlist|
            @rows << Row.new(kind: :playlist, playlist: playlist, depth: 1)
          end
        end
        @library.roots.each { |f| append_folder(f, 1, []) } if @expanded[:all]
        @selection = @selection.clamp(0, [@rows.size - 1, 0].max)
      end
```

`toggle_expand` — add a branch:

```ruby
        when :playlists
          @expanded[:playlists] = open
```

`breadcrumb_for` — before the folder branch:

```ruby
        return "Playlists / #{row.playlist['name']}" if row.kind == :playlist
```

`label_for` — new first branch:

```ruby
        if row.kind == :playlist
          ["#{@glyphs['playlist']} #{row.playlist['name']}", "(#{row.playlist['track_count']})"]
        elsif row.kind == :folder
```

New public method:

```ruby
      def select_playlist(id)
        @expanded[:playlists] = true
        rebuild!
        index = @rows.index { |r| r.kind == :playlist && r.playlist["id"] == id }
        @selection = index if index
        !!index
      end
```

- [ ] **Step 4: Run test file + full suite** — expected PASS. (Watch `app_test.rb`: sidebar row count grew by one fixed row; fix any index-hardcoded assertions there.)

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/views.rb lib/rubyplayer/ui/library_pane.rb test/library_pane_test.rb
git commit -m "feat(playlists): sidebar parent view with dynamic playlist children"
```

---

### Task 6: TracksPane — playlist-list mode and never-sorted playlist-tracks mode

**Files:**
- Modify: `lib/rubyplayer/ui/tracks_pane.rb`
- Test: `test/tracks_pane_test.rb`

**Interfaces:**
- Consumes: `Library#playlists`, `Library#playlist_tracks`, `LibraryPane::Row` with `:playlist`/`:playlists` kinds.
- Produces:
  - `show(row)` maps `:playlist` rows to mode `[:playlist, id]` and `:playlists` to `:playlists`.
  - `TracksPane#selected_playlist` → playlist hash or nil (only in `:playlists` mode).
  - `TracksPane#playlist_id` → Integer or nil (only in `[:playlist, id]` mode).
  - `:playlists` mode: rows of type `:playlist`; `sort_title` toggles alpha↔recency; group/other sorts return `[:disabled, msg]`.
  - `[:playlist, id]` mode: flat rows always; all sort/group actions return `[:disabled, msg]`.

- [ ] **Step 1: Write the failing tests**

Check `test/tracks_pane_test.rb` setup (it builds Library + config); reuse its helpers. Append:

```ruby
  def playlist_row(id, name: "P")
    RubyPlayer::UI::LibraryPane::Row.new(
      kind: :playlist, playlist: { "id" => id, "name" => name }, depth: 1
    )
  end

  def playlists_row
    RubyPlayer::UI::LibraryPane::Row.new(kind: :playlists, depth: 0)
  end

  def test_playlist_mode_shows_tracks_in_position_order
    id = @lib.create_playlist("P")
    b = add_track("/m/b.vgm", title: "B")
    a = add_track("/m/a.vgm", title: "A")
    @lib.add_to_playlist(id, b)
    @lib.add_to_playlist(id, a)
    @pane.show(playlist_row(id))
    assert_equal %w[B A], @pane.display_rows.map { |r| r[:track].title }
    assert_equal id, @pane.playlist_id
  end

  def test_playlist_mode_refuses_sort_and_group
    # Row index == playlist position is load-bearing (move/remove address it),
    # same regression class as the queue view being reordered by a stale @sort.
    id = @lib.create_playlist("P")
    @lib.add_to_playlist(id, add_track("/m/b.vgm", title: "B"))
    @lib.add_to_playlist(id, add_track("/m/a.vgm", title: "A"))
    @pane.show(playlist_row(id))
    outcome = @pane.handle_action(:sort_title)
    assert_equal :disabled, outcome[0]
    assert_equal %w[B A], @pane.display_rows.map { |r| r[:track].title }
    outcome = @pane.handle_action(:toggle_group)
    assert_equal :disabled, outcome[0]
  end

  def test_stale_sort_flag_does_not_reorder_playlist
    @pane.instance_variable_set(:@sort, :title)
    id = @lib.create_playlist("P")
    @lib.add_to_playlist(id, add_track("/m/b.vgm", title: "B"))
    @lib.add_to_playlist(id, add_track("/m/a.vgm", title: "A"))
    @pane.show(playlist_row(id))
    assert_equal %w[B A], @pane.display_rows.map { |r| r[:track].title }
  end

  def test_playlists_mode_lists_playlists_and_selects
    @lib.create_playlist("Alpha")
    beta = @lib.create_playlist("Beta")
    @pane.show(playlists_row)
    rows = @pane.display_rows
    assert(rows.all? { |r| r[:type] == :playlist })
    assert_equal "Beta", rows.first[:playlist]["name"] # recency default
    assert_equal beta, @pane.selected_playlist["id"]
    assert_nil @pane.selected_track
  end

  def test_playlists_mode_sort_title_toggles_alpha_and_recency
    @lib.create_playlist("Alpha")
    beta = @lib.create_playlist("Beta")
    # Second-resolution timestamps can tie; the rename bumps updated_at so
    # Beta is unambiguously most recent.
    @lib.rename_playlist(beta, "Beta")
    @pane.show(playlists_row)
    assert_equal %w[Beta Alpha], @pane.display_rows.map { |r| r[:playlist]["name"] }
    @pane.handle_action(:sort_title)
    assert_equal %w[Alpha Beta], @pane.display_rows.map { |r| r[:playlist]["name"] }
    @pane.handle_action(:sort_title)
    assert_equal %w[Beta Alpha], @pane.display_rows.map { |r| r[:playlist]["name"] }
  end

  def test_playlists_mode_filter_matches_names
    @lib.create_playlist("Battle Themes")
    @lib.create_playlist("Chill")
    @pane.show(playlists_row)
    @pane.filter = "batt"
    assert_equal ["Battle Themes"], @pane.display_rows.map { |r| r[:playlist]["name"] }
  end
```

**Timestamp note:** playlist timestamps use `iso8601(6)` (microseconds) precisely so recency ordering distinguishes same-second edits — the rename bump in the toggle test above is belt-and-braces, and add an inline comment in `create_playlist` explaining the precision choice.

- [ ] **Step 2: Run, verify failures** — `bundle exec ruby -Itest test/tracks_pane_test.rb`.

- [ ] **Step 3: Implement**

`tracks_pane.rb` — `require "time"` at the top. In `initialize`, add `@playlist_sort = :recency`.

`show`:

```ruby
        @mode =
          case library_row.kind
          when :folder then [:folder, library_row.folder["id"]]
          when :playlist then [:playlist, library_row.playlist["id"]]
          else library_row.kind
          end
```

`load_tracks` — new branches:

```ruby
          when :playlists then @library.playlists(sort: @playlist_sort)
          when Array
            @mode[0] == :playlist ? @library.playlist_tracks(@mode[1]) : @library.tracks_under(@mode[1])
```

New public accessors (near `selected_focus_sound`):

```ruby
      def selected_playlist
        row = display_rows[@selection]
        row && row[:type] == :playlist ? row[:playlist] : nil
      end

      # Non-nil only while showing a playlist's tracks — App's move/remove
      # entry actions gate on it.
      def playlist_id
        @mode.is_a?(Array) && @mode[0] == :playlist ? @mode[1] : nil
      end
```

`handle_action` — extend the existing gate at the top:

```ruby
        if playlist_tracks_view? &&
           %i[toggle_group sort_title sort_number sort_artist].include?(action)
          return [:disabled, "Playlist order is fixed — ctrl+arrows move tracks"]
        end
        if @mode == :playlists
          case action
          when :sort_title
            @playlist_sort = @playlist_sort == :alpha ? :recency : :alpha
            load_tracks
            clamp_selection
            return true
          when :toggle_group, :sort_number, :sort_artist
            return [:disabled, "Playlists sort by name/recency — Y toggles"]
          end
        end
```

`build_rows` — add before the `@group_by_album` check:

```ruby
        return playlist_rows if @mode == :playlists
        # Playlist tracks are position-ordered like the queue: headers would
        # break row-index == playlist-position, which move/remove rely on.
        return flat_rows if playlist_tracks_view?
```

`apply_sort` — extend the early return: `return if %i[queue focus playlists].include?(@mode) || playlist_tracks_view?`

`compute_filtered_tracks` — extend the values case:

```ruby
          values = if @mode == :focus
                     [item.title]
                   elsif @mode == :playlists
                     [item["name"]]
                   else
```

`selected_identity` / `restore_selection` — add `:playlist` branches:

```ruby
        when :playlist then [:playlist, row[:playlist]["id"]]
```
```ruby
          when :playlist then row[:type] == :playlist && row[:playlist]["id"] == identity[1]
```

`move_selection` — allow the type: `break if %i[track focus playlist].include?(rows[i][:type])`

`empty_message` — add: `when :playlists then "No playlists yet — press L on a track to create one"`

New private methods:

```ruby
      def playlist_tracks_view?
        @mode.is_a?(Array) && @mode[0] == :playlist
      end

      def playlist_rows
        filtered_tracks.map do |p|
          count = "  (#{p['track_count']})"
          used = "  #{relative_time(p['updated_at'])}"
          { type: :playlist, text: "#{p['name']}#{count}#{used}",
            segments: [{ text: p["name"], bold: true },
                       { text: count, fg: :text_muted },
                       { text: used, fg: :text_muted }],
            playlist: p }
        end
      end

      def relative_time(iso)
        seconds = Time.now.utc - Time.parse(iso)
        return "just now" if seconds < 60
        return "#{(seconds / 60).to_i}m ago" if seconds < 3600
        return "#{(seconds / 3600).to_i}h ago" if seconds < 86_400

        "#{(seconds / 86_400).to_i}d ago"
      end
```

- [ ] **Step 4: Run test file + full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/tracks_pane.rb test/tracks_pane_test.rb
git commit -m "feat(playlists): tracks-pane playlist list and never-sorted playlist view"
```

---

### Task 7: App — playlist playback, jump-from-list, move/remove entries

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/app_test.rb` (methods ABOVE `private`!)

**Interfaces:**
- Consumes: everything above.
- Produces: `App#dispatch` handles `:move_entry_up`, `:move_entry_down`; `x` (`:remove_from_queue`) removes playlist entries in playlist views; `enter` on a playlist row in the list jumps into it; enqueueing a sidebar playlist child enqueues its visible tracks.

- [ ] **Step 1: Write the failing tests**

Use the existing `make_app` helper; remember `@app.shutdown` before any second App in one test (native audio shim is one-instance-per-process). Seed data through `app.instance_variable_get(:@library)`. Add ABOVE `private`:

```ruby
  def test_selected_tracks_for_sidebar_playlist_child
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "M", path: "/m", kind: "dir")
    tid = lib.upsert_track(folder_id: root, physical_path: "/m/a.vgm", backend: "gme",
                           format: "vgm", title: "A", album: "Al", artist: "Ar",
                           composer: "C", track_number: 1, duration_ms: 1000)
    pid = lib.create_playlist("P")
    lib.add_to_playlist(pid, tid)
    pane = @app.library_pane
    pane.rebuild!
    assert pane.select_playlist(pid)
    assert_equal ["A"], @app.selected_tracks.map(&:title)
  end

  def test_enter_on_playlist_list_row_jumps_into_playlist
    lib = @app.instance_variable_get(:@library)
    pid = lib.create_playlist("P")
    pane = @app.library_pane
    pane.rebuild!
    playlists_index = pane.rows.index { |r| r.kind == :playlists }
    pane.instance_variable_set(:@selection, playlists_index)
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :tracks)
    @app.handle_key("enter")
    assert_equal :playlist, pane.selected.kind
    assert_equal pid, pane.selected.playlist["id"]
    assert_equal pid, @app.tracks_pane.playlist_id
  end

  def test_ctrl_down_moves_playlist_entry_and_selection_follows
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "M", path: "/m", kind: "dir")
    ids = %w[a b].map do |n|
      lib.upsert_track(folder_id: root, physical_path: "/m/#{n}.vgm", backend: "gme",
                       format: "vgm", title: n.upcase, album: "Al", artist: "Ar",
                       composer: "C", track_number: 1, duration_ms: 1000)
    end
    pid = lib.create_playlist("P")
    ids.each { |t| lib.add_to_playlist(pid, t) }
    @app.library_pane.rebuild!
    @app.library_pane.select_playlist(pid)
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :tracks)
    @app.handle_key("ctrl_down") # move A below B
    assert_equal %w[B A], lib.playlist_tracks(pid).map(&:title)
    # Selection follows the moved track (reload! restores by identity).
    assert_equal "A", @app.tracks_pane.selected_track.title
  end

  def test_x_removes_playlist_entry
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "M", path: "/m", kind: "dir")
    tid = lib.upsert_track(folder_id: root, physical_path: "/m/a.vgm", backend: "gme",
                           format: "vgm", title: "A", album: "Al", artist: "Ar",
                           composer: "C", track_number: 1, duration_ms: 1000)
    pid = lib.create_playlist("P")
    lib.add_to_playlist(pid, tid)
    @app.library_pane.rebuild!
    @app.library_pane.select_playlist(pid)
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :tracks)
    @app.handle_key("x")
    assert_empty lib.playlist_tracks(pid)
  end

  def test_move_refused_while_filter_active
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "M", path: "/m", kind: "dir")
    ids = %w[a b].map do |n|
      lib.upsert_track(folder_id: root, physical_path: "/m/#{n}.vgm", backend: "gme",
                       format: "vgm", title: n.upcase, album: "Al", artist: "Ar",
                       composer: "C", track_number: 1, duration_ms: 1000)
    end
    pid = lib.create_playlist("P")
    ids.each { |t| lib.add_to_playlist(pid, t) }
    @app.library_pane.rebuild!
    @app.library_pane.select_playlist(pid)
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :tracks)
    @app.tracks_pane.filter = "B"
    @app.handle_key("ctrl_down")
    assert_equal %w[A B], lib.playlist_tracks(pid).map(&:title)
  end
```

- [ ] **Step 2: Run, verify failures** — `bundle exec ruby -Itest test/app_test.rb`. Confirm the new tests actually RUN (count went up) — if the run count didn't grow, they're below `private`.

- [ ] **Step 3: Implement in `app.rb`**

`selected_tracks` — extend the library-pane branch:

```ruby
          row = @library_pane.selected
          if row&.kind == :folder
            @library.tracks_under(row.folder["id"])
          elsif row&.kind == :playlist
            # Visible entries only: hidden-missing tracks can't play anyway.
            @library.playlist_tracks(row.playlist["id"])
          else
```

`play_now` — new first branch:

```ruby
      def play_now
        if (playlist = @active_pane == :tracks && @tracks_pane.selected_playlist)
          return jump_to_playlist(playlist)
        end
        sound = selected_focus_sound
        return play_focus(sound) if sound

        enqueue(:now)
      end
```

New methods (near `select_queue`):

```ruby
      # Enter on a row of the playlist LIST opens the playlist rather than
      # playing it — the list is a navigation surface; playback starts from
      # the sidebar child or from inside the playlist.
      def jump_to_playlist(playlist)
        @library_pane.select_playlist(playlist["id"])
        show_selected_tracks
        @active_pane = :tracks
      end

      def move_playlist_entry(delta)
        id = @tracks_pane.playlist_id
        return @status_line.set_message("Open a playlist to reorder tracks") unless id
        # Filtered rows hide neighbors: the visible index the user sees no
        # longer matches the playlist's visible position, so a move would hit
        # the wrong entry. Refuse instead of guessing.
        return @status_line.set_message("Clear the filter before reordering") unless @tracks_pane.filter.empty?

        index = @tracks_pane.selected_track_index
        return unless index

        moved = @library.move_playlist_entry(id, index, delta)
        return unless moved

        # reload! restores selection by track identity, so the highlight
        # follows the moved track without explicit index bookkeeping.
        @tracks_pane.reload!
        @library_pane.rebuild! # updated_at bumped: recency order may shift
      end

      def remove_playlist_entry
        id = @tracks_pane.playlist_id
        return unless id
        return @status_line.set_message("Clear the filter before removing") unless @tracks_pane.filter.empty?

        index = @tracks_pane.selected_track_index
        return unless index

        removed = @library.remove_playlist_entry(id, index)
        return unless removed

        @tracks_pane.reload!
        @library_pane.rebuild!
        @status_line.set_message("Removed from playlist")
      end
```

`dispatch` — add cases:

```ruby
        when :move_entry_up then move_playlist_entry(-1)
        when :move_entry_down then move_playlist_entry(1)
```

and change the `:remove_from_queue` case:

```ruby
        when :remove_from_queue
          # Same key, view-dependent meaning: in a playlist view "x" removes
          # the entry; everywhere else it keeps its queue semantics.
          @tracks_pane.playlist_id ? remove_playlist_entry : remove_from_queue
```

**Caution:** the tracks pane keeps its mode when the library selection moves elsewhere only via `show` — `playlist_id` is non-nil exactly while a playlist's tracks are displayed, which is the correct gate.

- [ ] **Step 4: Run test file + full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/app.rb test/app_test.rb
git commit -m "feat(playlists): playback, list jump-in, and entry move/remove wiring"
```

---

### Task 8: App — add-to-playlist modal

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/app_test.rb` (above `private`)

**Interfaces:**
- Consumes: `Library#playlists/create_playlist/add_to_playlist/playlist_contains?`, `edit_line`, `render_modal`, config `"playlist_recent_count"`.
- Produces: `@playlist_modal` state hash `{ track:, filter:, selection:, confirm:, error: }`, `attr_reader :playlist_modal`; `handle_playlist_modal_key(key)`; `playlist_modal_rows` (rows of `{kind: :playlist, playlist:, recent: bool}` plus `{kind: :create}` when filter non-blank); `render_playlist_modal`.

- [ ] **Step 1: Write the failing tests**

Add ABOVE `private` in `test/app_test.rb`:

```ruby
  def seed_track_and_show_all
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "M", path: "/m", kind: "dir")
    tid = lib.upsert_track(folder_id: root, physical_path: "/m/a.vgm", backend: "gme",
                          format: "vgm", title: "A", album: "Al", artist: "Ar",
                          composer: "C", track_number: 1, duration_ms: 1000)
    pane = @app.library_pane
    pane.rebuild!
    pane.instance_variable_set(:@selection, pane.rows.index { |r| r.kind == :all })
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :tracks)
    [lib, tid]
  end

  def test_l_opens_add_modal_and_typing_a_name_creates_playlist_with_track
    lib, tid = seed_track_and_show_all
    @app.handle_key("l")
    refute_nil @app.playlist_modal
    "Mix".each_char { |ch| @app.handle_key(ch) }
    @app.handle_key("enter") # only row is "New playlist: Mix"
    assert_nil @app.playlist_modal
    lists = lib.playlists
    assert_equal ["Mix"], lists.map { |p| p["name"] }
    assert_equal [tid], lib.playlist_tracks(lists.first["id"]).map(&:id)
  end

  def test_add_modal_picks_existing_playlist
    lib, tid = seed_track_and_show_all
    pid = lib.create_playlist("Mix")
    @app.handle_key("l")
    @app.handle_key("enter") # first row: recent "Mix"
    assert_nil @app.playlist_modal
    assert_equal [tid], lib.playlist_tracks(pid).map(&:id)
  end

  def test_add_modal_confirms_duplicates
    lib, tid = seed_track_and_show_all
    pid = lib.create_playlist("Mix")
    lib.add_to_playlist(pid, tid)
    @app.handle_key("l")
    @app.handle_key("enter")
    refute_nil @app.playlist_modal[:confirm] # already contains the track
    @app.handle_key("n")
    assert_nil @app.playlist_modal[:confirm] # back to the list
    @app.handle_key("enter")
    @app.handle_key("y")
    assert_nil @app.playlist_modal
    assert_equal [tid, tid], lib.playlist_tracks(pid).map(&:id)
  end

  def test_add_modal_escape_cancels
    seed_track_and_show_all
    @app.handle_key("l")
    @app.handle_key("escape")
    assert_nil @app.playlist_modal
  end

  def test_l_without_selected_track_shows_message_not_modal
    @app.instance_variable_set(:@active_pane, :library)
    @app.handle_key("l")
    assert_nil @app.playlist_modal
  end
```

- [ ] **Step 2: Run, verify failures.** Confirm the run count grew.

- [ ] **Step 3: Implement in `app.rb`**

Add `:playlist_modal` to the `attr_reader` list. In `initialize` (near `@pending_delete = nil`): `@playlist_modal = nil`.

`handle_key` — insert after the `@pending_delete` line, BEFORE the Paste check (a paste mid-modal must not fall through to the path-scanner):

```ruby
        return handle_playlist_modal_key(key) if @playlist_modal
```

`modal_active?` — add `@playlist_modal` to the list.

`dispatch` — add: `when :add_to_playlist then request_add_to_playlist`

New methods (a `# ---- playlists ----` section near the other request_ methods):

```ruby
      def request_add_to_playlist
        track = @active_pane == :tracks && @tracks_pane.selected_track
        return @status_line.set_message("Select a track to add to a playlist") unless track

        @playlist_modal = { track: track, filter: "", selection: 0, confirm: nil, error: nil }
      end

      # Recent direct-picks first, then the alphabetical list narrowed by the
      # filter, then the create row (the filter text doubles as the name — a
      # playlist is always born holding at least one track).
      def playlist_modal_rows
        filter = @playlist_modal[:filter].strip
        needle = filter.downcase
        recent = @library.playlists(sort: :recency).first(@config["ui", "playlist_recent_count"])
        all = @library.playlists(sort: :alpha)
        all = all.select { |p| p["name"].downcase.include?(needle) } unless needle.empty?
        rows = recent.map { |p| { kind: :playlist, playlist: p, recent: true } }
        rows += all.map { |p| { kind: :playlist, playlist: p } }
        rows << { kind: :create } unless filter.empty?
        rows
      end

      def handle_playlist_modal_key(key)
        return unless key.is_a?(String) # swallow pastes; they aren't names

        modal = @playlist_modal
        if (playlist = modal[:confirm])
          case key
          when "y", "enter"
            @playlist_modal = nil
            add_track_to_playlist(playlist, modal[:track])
          when "n", "escape" then modal[:confirm] = nil
          end
          return
        end

        rows = playlist_modal_rows
        case key
        when "escape" then @playlist_modal = nil
        when "up" then modal[:selection] = (modal[:selection] - 1).clamp(0, [rows.size - 1, 0].max)
        when "down" then modal[:selection] = (modal[:selection] + 1).clamp(0, [rows.size - 1, 0].max)
        when "enter"
          row = rows[modal[:selection]]
          return unless row

          if row[:kind] == :create
            create_playlist_and_add(modal[:filter].strip, modal[:track])
          elsif @library.playlist_contains?(row[:playlist]["id"], modal[:track].id)
            modal[:confirm] = row[:playlist]
          else
            @playlist_modal = nil
            add_track_to_playlist(row[:playlist], modal[:track])
          end
        else
          edited = edit_line(modal[:filter], key)
          if edited
            modal[:filter] = edited
            modal[:error] = nil
            # The row list just changed shape under the cursor.
            modal[:selection] = modal[:selection].clamp(0, [playlist_modal_rows.size - 1, 0].max)
          end
        end
      end

      def add_track_to_playlist(playlist, track)
        @library.add_to_playlist(playlist["id"], track.id)
        @library_pane.rebuild!
        @tracks_pane.reload!
        @status_line.set_message("Added to \"#{playlist['name']}\"")
      rescue Library::PlaylistError => e
        @status_line.set_message(e.message)
      end

      def create_playlist_and_add(name, track)
        id = @library.create_playlist(name)
        @playlist_modal = nil
        @library.add_to_playlist(id, track.id)
        @library_pane.rebuild!
        @status_line.set_message("Created \"#{name}\" and added track")
      rescue Library::PlaylistNameTaken => e
        # Keep the modal open so the user can adjust the name in place.
        @playlist_modal[:error] = e.message if @playlist_modal
      rescue Library::PlaylistError => e
        @status_line.set_message(e.message)
      end
```

`render` — add with the other modal renders, after `render_now_playing_modal`:

```ruby
        render_playlist_modal if @playlist_modal
```

Render implementation (with the other render_* methods):

```ruby
      def render_playlist_modal
        modal = @playlist_modal
        if (playlist = modal[:confirm])
          message = "Already in \"#{playlist['name']}\". Add again?"
          prompt = "[y] Add duplicate    [n/esc] Back"
          w = [message.size, prompt.size].max + 4
          render_modal(title: "Add to Playlist", w: w, h: 5) do |x, y|
            @screen.put(y + 2, x + 2, message[0, w - 4], fg: @theme[:accent], bold: true)
            @screen.put(y + 3, x + 2, prompt[0, w - 4], fg: @theme[:primary], bold: true)
          end
          return
        end

        rows = playlist_modal_rows
        labels = rows.map do |row|
          if row[:kind] == :create
            "+ New playlist: #{modal[:filter].strip}"
          else
            "#{row[:recent] ? '* ' : '  '}#{row[:playlist]['name']} (#{row[:playlist]['track_count']})"
          end
        end
        labels = ["(no playlists — type a name)"] if labels.empty?
        labels = labels.first([@screen.rows - 9, 1].max) # tiny terminals: keep chrome visible
        filter_line = "Filter/name: #{modal[:filter]}_"
        hint = "[enter] Add  [esc] Cancel"
        w = [(labels.map(&:size) + [filter_line.size, hint.size,
                                    (modal[:error] || "").size]).max + 6, @screen.cols - 2].min
        h = labels.size + (modal[:error] ? 6 : 5)
        render_modal(title: "Add to Playlist", w: w, h: h, hint: hint) do |x, y|
          @screen.put(y + 1, x + 2, filter_line[0, w - 4], fg: @theme[:accent])
          labels.each_with_index do |label, i|
            selected = !rows.empty? && i == modal[:selection]
            bg = selected ? @theme[:selection_bg] : nil
            fg = selected ? @theme[:selection_text] : @theme[:text]
            @screen.put(y + 2 + i, x + 1, " " * (w - 2), bg: bg) if selected
            @screen.put(y + 2 + i, x + 2, label[0, w - 4], fg: fg, bg: bg, bold: selected)
          end
          @screen.put(y + h - 3, x + 2, modal[:error][0, w - 4], fg: @theme[:error]) if modal[:error]
        end
      end
```

- [ ] **Step 4: Run test file + full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/app.rb test/app_test.rb
git commit -m "feat(playlists): add-to-playlist modal with inline create and duplicate confirm"
```

---

### Task 9: App — rename/duplicate name prompt and delete confirm

**Files:**
- Modify: `lib/rubyplayer/ui/app.rb`
- Test: `test/app_test.rb` (above `private`)

**Interfaces:**
- Consumes: `Library#rename_playlist/duplicate_playlist/delete_playlist`, `PlaylistNameTaken`, `render_modal`, `edit_line`.
- Produces: `@name_prompt` `{ op: :rename|:duplicate, playlist:, buffer:, error: }` + `attr_reader :name_prompt`; `@pending_playlist_delete` (playlist hash) + `attr_reader :pending_playlist_delete`; extended `request_remove_library_item`.

- [ ] **Step 1: Write the failing tests**

Add ABOVE `private`:

```ruby
  def select_playlist_child(pid)
    @app.library_pane.rebuild!
    @app.library_pane.select_playlist(pid)
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :library)
  end

  def test_r_renames_selected_playlist
    lib = @app.instance_variable_get(:@library)
    pid = lib.create_playlist("Old")
    select_playlist_child(pid)
    @app.handle_key("r")
    refute_nil @app.name_prompt
    3.times { @app.handle_key("backspace") }
    "New".each_char { |ch| @app.handle_key(ch) }
    @app.handle_key("enter")
    assert_nil @app.name_prompt
    assert_equal ["New"], lib.playlists.map { |p| p["name"] }
  end

  def test_rename_to_taken_name_shows_error_and_keeps_prompt
    lib = @app.instance_variable_get(:@library)
    lib.create_playlist("Taken")
    pid = lib.create_playlist("Mine")
    select_playlist_child(pid)
    @app.handle_key("r")
    4.times { @app.handle_key("backspace") }
    "Taken".each_char { |ch| @app.handle_key(ch) }
    @app.handle_key("enter")
    refute_nil @app.name_prompt
    refute_nil @app.name_prompt[:error]
  end

  def test_c_duplicates_playlist_with_entries
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "M", path: "/m", kind: "dir")
    tid = lib.upsert_track(folder_id: root, physical_path: "/m/a.vgm", backend: "gme",
                           format: "vgm", title: "A", album: "Al", artist: "Ar",
                           composer: "C", track_number: 1, duration_ms: 1000)
    pid = lib.create_playlist("Mix")
    lib.add_to_playlist(pid, tid)
    select_playlist_child(pid)
    @app.handle_key("c")
    assert_equal "Mix copy", @app.name_prompt[:buffer]
    @app.handle_key("enter")
    names = lib.playlists(sort: :alpha).map { |p| p["name"] }
    assert_equal ["Mix", "Mix copy"], names
    copy = lib.playlists(sort: :alpha).last
    assert_equal [tid], lib.playlist_tracks(copy["id"]).map(&:id)
  end

  def test_x_on_playlist_child_asks_then_deletes
    lib = @app.instance_variable_get(:@library)
    pid = lib.create_playlist("Doomed")
    select_playlist_child(pid)
    @app.handle_key("x")
    refute_nil @app.pending_playlist_delete
    @app.handle_key("y")
    assert_nil @app.pending_playlist_delete
    assert_empty lib.playlists
  end

  def test_x_on_playlist_delete_can_cancel
    lib = @app.instance_variable_get(:@library)
    pid = lib.create_playlist("Kept")
    select_playlist_child(pid)
    @app.handle_key("x")
    @app.handle_key("n")
    assert_nil @app.pending_playlist_delete
    assert_equal 1, lib.playlists.size
  end

  def test_rename_on_non_playlist_row_is_message_only
    @app.library_pane.rebuild!
    @app.library_pane.handle_action(:select_queue)
    @app.instance_variable_set(:@active_pane, :library)
    @app.handle_key("r")
    assert_nil @app.name_prompt
  end
```

- [ ] **Step 2: Run, verify failures.** Confirm run count grew.

- [ ] **Step 3: Implement in `app.rb`**

Add `:name_prompt, :pending_playlist_delete` to `attr_reader`. In `initialize`: `@name_prompt = nil` and `@pending_playlist_delete = nil`.

`handle_key` — insert directly above the `@playlist_modal` line (delete confirm outranks the other playlist states, mirroring the existing confirm ordering):

```ruby
        return handle_playlist_delete_key(key) if @pending_playlist_delete
        return handle_name_prompt_key(key) if @name_prompt
```

`modal_active?` — add `@name_prompt || @pending_playlist_delete`.

`dispatch` — add:

```ruby
        when :rename_playlist then request_playlist_name(:rename)
        when :duplicate_playlist then request_playlist_name(:duplicate)
```

`request_remove_library_item` — new branch before the folder check:

```ruby
        row = @library_pane.selected
        if row&.kind == :playlist
          @pending_playlist_delete = row.playlist
          return
        end
        if row&.kind != :folder
```

New methods:

```ruby
      # c/r act on the specific playlist under the cursor — the parent row
      # names no playlist, so it only earns a hint.
      def request_playlist_name(op)
        row = @library_pane.selected
        return @status_line.set_message("Select a playlist first") unless row&.kind == :playlist

        buffer = op == :duplicate ? "#{row.playlist['name']} copy" : row.playlist["name"].dup
        @name_prompt = { op: op, playlist: row.playlist, buffer: buffer, error: nil }
      end

      def handle_name_prompt_key(key)
        return unless key.is_a?(String)

        prompt = @name_prompt
        case key
        when "escape" then @name_prompt = nil
        when "enter"
          name = prompt[:buffer].strip
          return prompt[:error] = "Name cannot be blank" if name.empty?

          begin
            if prompt[:op] == :rename
              @library.rename_playlist(prompt[:playlist]["id"], name)
              @status_line.set_message("Renamed to \"#{name}\"")
            else
              @library.duplicate_playlist(prompt[:playlist]["id"], name)
              @status_line.set_message("Duplicated as \"#{name}\"")
            end
            @name_prompt = nil
            @library_pane.rebuild!
            show_selected_tracks
          rescue Library::PlaylistNameTaken => e
            prompt[:error] = e.message
          end
        else
          edited = edit_line(prompt[:buffer], key)
          if edited
            prompt[:buffer] = edited
            prompt[:error] = nil
          end
        end
      end

      def handle_playlist_delete_key(key)
        case key
        when "y", "enter"
          playlist = @pending_playlist_delete
          @pending_playlist_delete = nil
          @library.delete_playlist(playlist["id"])
          @library_pane.rebuild!
          show_selected_tracks
          @status_line.set_message("Deleted playlist \"#{playlist['name']}\"")
        when "n", "escape" then @pending_playlist_delete = nil
        end
      end
```

`render` — add after `render_playlist_modal`:

```ruby
        render_name_prompt_modal if @name_prompt
        render_playlist_delete_modal if @pending_playlist_delete
```

Render implementations:

```ruby
      def render_name_prompt_modal
        prompt = @name_prompt
        title = prompt[:op] == :rename ? "Rename Playlist" : "Duplicate Playlist"
        line = "Name: #{prompt[:buffer]}_"
        hint = "[enter] Save  [esc] Cancel"
        w = [[line.size, hint.size, (prompt[:error] || "").size].max + 6, @screen.cols - 2].min
        render_modal(title: title, w: w, h: 6, hint: hint) do |x, y|
          @screen.put(y + 2, x + 2, line[0, w - 4], fg: @theme[:accent], bold: true)
          @screen.put(y + 3, x + 2, prompt[:error][0, w - 4], fg: @theme[:error]) if prompt[:error]
        end
      end

      def render_playlist_delete_modal
        message = "Delete playlist \"#{@pending_playlist_delete['name']}\"?"
        prompt = "[y] Delete    [n/esc] Cancel"
        w = [message.size, prompt.size].max + 4
        render_modal(title: "Confirm Delete", w: w, h: 5) do |x, y|
          @screen.put(y + 2, x + 2, message[0, w - 4], fg: @theme[:accent], bold: true)
          @screen.put(y + 3, x + 2, prompt[0, w - 4], fg: @theme[:primary], bold: true)
        end
      end
```

- [ ] **Step 4: Run test file + full suite** — expected PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/app.rb test/app_test.rb
git commit -m "feat(playlists): rename/duplicate name prompt and delete confirmation"
```

---

## Final verification

- [ ] Full suite: `bundle exec rake test` — all green, run count grew by ~30 vs. the pre-feature baseline (362).
- [ ] Manual TTY check (user does this — app can't run headlessly): launch, note the DB rebuild message path (schema v2 rebuild + rescan expected once), press `L` on a track, type a name, Enter; confirm sidebar shows Playlists with the child; open it; `ctrl+arrows` reorder; `x` removes; `c`/`r`/`x` from the sidebar duplicate/rename/delete.
- [ ] Update `README.md` per-file reference if it lists Library methods (check; amend the last commit if trivial).
