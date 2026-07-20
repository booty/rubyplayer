# Rich Metadata Ingestion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ingest full ffprobe tag sets (ID3v1/v2, MP4, FLAC/Vorbis) — two promoted columns (`album_artist`, `year`) plus KV sidecar rows — with path-derived album/title fallbacks baked at scan time, and expose the new fields to grouping, sorting, and the info modal.

**Architecture:** Schema v3 adds two narrow columns to `tracks`; the existing `track_metadata` KV table absorbs everything else. The ffmpeg backend's `metadata` gains `:album_artist`, `:year`, `:extra`; `ExtractorPool` computes album fallbacks (it alone knows folder/archive/multitrack context) and persists KV rows. UI: grouping key gains album_artist, new `sort_year`, info modal shows the extras.

**Tech Stack:** Ruby 4.0.1 (mise), sqlite3, ffprobe (already a runtime dependency), minitest.

**Spec:** `docs/superpowers/specs/2026-07-20-rich-metadata-design.md`.

## Global Constraints

- Every test/commit command first: `export PATH="$HOME/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"` and `set -o pipefail` (mise exec unreliable; unpiped rake exit status gets masked otherwise).
- TDD: failing test first, watch it fail, minimal code to green. Full suite (`bundle exec rake test`) green before every commit. One commit per task.
- Comments explain why, not what. No magic numbers — config `DEFAULTS`.
- `test/app_test.rb`: new test methods go ABOVE the `private` keyword (Minitest silently skips tests defined after it).
- The app cannot run headlessly. Verify via suite only.

---

### Task 1: Schema v3, Track fields, Library metadata persistence

**Files:**
- Modify: `lib/rubyplayer/database.rb` (SCHEMA_VERSION 2→3; two columns in `tracks`)
- Modify: `lib/rubyplayer/track.rb`
- Modify: `lib/rubyplayer/library.rb` (`upsert_track`, new KV methods)
- Test: `test/library_test.rb` (new tests go above the `private` near the bottom)

**Interfaces:**
- Consumes: existing `Database`, `Track.from_row`, `Library#upsert_track`.
- Produces (later tasks rely on exact shapes):
  - `tracks` columns `album_artist TEXT`, `year INTEGER` (nullable), positioned after `composer` in the CREATE TABLE.
  - `Track` struct members `:album_artist`, `:year` (after `:composer`), hydrated by `from_row`.
  - `Library#upsert_track(attrs)` accepts `:album_artist` and `:year` keys (default nil) and persists/updates them like the other tag columns.
  - `Library#replace_track_metadata(track_id, pairs)` — deletes the track's existing KV rows and inserts `pairs` (Hash of String=>String), one transaction. Empty/nil hash just clears.
  - `Library#track_metadata_for(track_id)` — returns Hash of String=>String (empty hash when none).

- [ ] **Step 1: Write failing tests** — append to `test/library_test.rb` ABOVE its `private` line:

```ruby
  # ---- rich metadata (see docs/superpowers/specs/2026-07-20-rich-metadata-design.md) ----

  def test_upsert_track_persists_album_artist_and_year
    id = @lib.upsert_track(folder_id: @sub, physical_path: "/m/sega/meta.mp3",
                           backend: "ffmpeg", format: "mp3", title: "T", album: "A",
                           artist: "Ar", composer: nil, track_number: 1,
                           duration_ms: 1000, album_artist: "Various", year: 1998)
    t = @lib.find_track(id)
    assert_equal "Various", t.album_artist
    assert_equal 1998, t.year
  end

  def test_upsert_track_defaults_album_artist_and_year_to_nil
    id = add_track("/m/sega/plain.vgm")
    t = @lib.find_track(id)
    assert_nil t.album_artist
    assert_nil t.year
  end

  def test_replace_track_metadata_round_trip_and_replacement
    id = add_track("/m/sega/kv.vgm")
    @lib.replace_track_metadata(id, { "genre" => "VGM", "comment" => "rip" })
    assert_equal({ "genre" => "VGM", "comment" => "rip" }, @lib.track_metadata_for(id))
    # Replacement is total: stale keys from the previous scan must not linger.
    @lib.replace_track_metadata(id, { "genre" => "Chip" })
    assert_equal({ "genre" => "Chip" }, @lib.track_metadata_for(id))
    @lib.replace_track_metadata(id, {})
    assert_empty @lib.track_metadata_for(id)
  end
```

- [ ] **Step 2: Run, verify failure**

```bash
export PATH="$HOME/.local/share/mise/installs/ruby/4.0.1/bin:$PATH"
set -o pipefail
bundle exec ruby -Itest test/library_test.rb 2>&1 | tail -3
```
Expected: errors (`no such column: album_artist` / `undefined method 'replace_track_metadata'`).

- [ ] **Step 3: Implement**

`database.rb`: `SCHEMA_VERSION = 3`. In the `tracks` CREATE TABLE, change the tag line to:

```sql
        title TEXT, album TEXT, artist TEXT, composer TEXT,
        album_artist TEXT,                        -- ID3 TPE2 / MP4 aART / Vorbis ALBUMARTIST
        year INTEGER,                             -- normalized 4-digit release year
```

`track.rb`: add `:album_artist, :year` to the Struct member list right after `:composer`, and to `from_row`:

```ruby
          album_artist: row["album_artist"], year: row["year"],
```

`library.rb` `upsert_track`: add `album_artist: nil, year: nil` to the defaults-merge hash; add the two columns to the INSERT column list, two `?` placeholders, `album_artist=excluded.album_artist, year=excluded.year` to the ON CONFLICT UPDATE, and `a[:album_artist], a[:year]` to the bind array (keep positional order consistent with the column list).

New methods (near the other track mutators):

```ruby
    # Total replacement, not merge: the scan is the single source of truth
    # for file-derived metadata, and a tag deleted from the file must not
    # linger from an earlier scan.
    def replace_track_metadata(track_id, pairs)
      @db.write do |s|
        s.execute("DELETE FROM track_metadata WHERE track_id = ?", [track_id])
        (pairs || {}).each do |key, value|
          s.execute("INSERT INTO track_metadata (track_id, key, value) VALUES (?, ?, ?)",
                    [track_id, key.to_s, value.to_s])
        end
      end
    end

    def track_metadata_for(track_id)
      @db.read do |s|
        s.execute("SELECT key, value FROM track_metadata WHERE track_id = ?", [track_id])
         .to_h { |r| [r["key"], r["value"]] }
      end
    end
```

- [ ] **Step 4: Run test file + full suite** — both green:

```bash
bundle exec ruby -Itest test/library_test.rb 2>&1 | tail -2
bundle exec rake test 2>&1 | tail -2
```

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/database.rb lib/rubyplayer/track.rb lib/rubyplayer/library.rb test/library_test.rb
git commit -m "feat(metadata): schema v3 with album_artist/year columns and KV persistence"
```

---

### Task 2: Ffmpeg backend — album_artist, year, scrubbed extra tags

**Files:**
- Modify: `lib/rubyplayer/backends/ffmpeg.rb`
- Modify: `lib/rubyplayer/config.rb` (one DEFAULTS entry)
- Test: `test/ffmpeg_backend_test.rb`

**Interfaces:**
- Consumes: existing `Ffmpeg#metadata` / `#probe` / `#merged_tags` / `#normalize_tags` / `#presence`.
- Produces: `Ffmpeg#metadata(path, subtune)` result hash gains three keys consumed by Task 3:
  - `:album_artist` → String or nil (from the `album_artist` tag; ffprobe already maps TPE2/aART/ALBUMARTIST to it after our downcasing).
  - `:year` → Integer or nil — first 4-digit number in 1000..2999 scanned from, in order, tags `date`, `year`, `tdrc`, `tdrl`, `originaldate`.
  - `:extra` → Hash(String=>String) of every remaining normalized tag EXCEPT the consumed ones (`%w[title album artist album_artist composer track]`), keys downcased, values scrubbed and truncated.
- Produces config key: `RubyPlayer::DEFAULTS["library"]["metadata_value_limit"] = 8192` (bytes). The backend cannot see config, so the limit is applied with a class-level constant default that reads the same number — see Step 3 note.

- [ ] **Step 1: Write failing tests** — open `test/ffmpeg_backend_test.rb` first and match its existing setup idiom. Add:

```ruby
  def tagged_fixture(dir, tags)
    path = File.join(dir, "tagged.mp3")
    args = tags.flat_map { |k, v| ["-metadata", "#{k}=#{v}"] }
    system("ffmpeg", "-hide_banner", "-loglevel", "error",
           "-f", "lavfi", "-i", "sine=frequency=440:duration=0.2",
           *args, path, exception: true)
    path
  end

  def test_metadata_extracts_album_artist_year_and_extra_tags
    Dir.mktmpdir do |dir|
      path = tagged_fixture(dir, "album_artist" => "Various Artists",
                                 "date" => "1998-11-20", "genre" => "Rock",
                                 "album" => "Hits", "title" => "Song")
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)
      assert_equal "Various Artists", meta[:album_artist]
      assert_equal 1998, meta[:year]
      assert_equal "Rock", meta[:extra]["genre"]
      assert_equal "1998-11-20", meta[:extra]["date"] # raw date preserved in extras
      refute_includes meta[:extra].keys, "title"      # consumed keys excluded
      refute_includes meta[:extra].keys, "album_artist"
    end
  end

  def test_metadata_year_nil_when_absent_or_implausible
    Dir.mktmpdir do |dir|
      path = tagged_fixture(dir, "date" => "not a date", "title" => "Song")
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)
      assert_nil meta[:year]
    end
  end

  def test_metadata_scrubs_invalid_utf8_and_caps_value_size
    Dir.mktmpdir do |dir|
      long = "x" * 10_000
      path = tagged_fixture(dir, "comment" => long, "title" => "Song")
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)
      limit = RubyPlayer::DEFAULTS["library"]["metadata_value_limit"]
      assert_operator meta[:extra]["comment"].bytesize, :<=, limit
      # Scrubbing guarantee: every stored value is valid UTF-8 (mislabeled
      # ID3 encodings otherwise crash Ruby string ops far from the scan).
      assert meta[:extra].values.all?(&:valid_encoding?)
    end
  end
```

(`require "tmpdir"` at the top of the test file if not present.)

- [ ] **Step 2: Run, verify failure** — `bundle exec ruby -Itest test/ffmpeg_backend_test.rb 2>&1 | tail -3`. Expected: nil `:album_artist` / missing `:extra` assertions fail.

- [ ] **Step 3: Implement**

`config.rb` DEFAULTS `"library"` — add after `"archive_tool"`:

```ruby
      # Byte cap per stored tag value; a corrupt frame must not bloat the DB.
      "metadata_value_limit" => 8192,
```

`ffmpeg.rb` — backends are constructed by the registry without config access, so the cap references the same DEFAULTS entry rather than duplicating the number:

```ruby
      CONSUMED_TAGS = %w[title album artist album_artist composer track].freeze
```

In `metadata`, extend the returned hash:

```ruby
        {
          title: presence(tags["title"]) || File.basename(path, ".*"),
          album: presence(tags["album"]),
          artist: presence(tags["artist"]) || presence(tags["album_artist"]),
          album_artist: presence(tags["album_artist"]),
          composer: presence(tags["composer"]),
          track_number: parse_track_number(tags["track"]),
          year: parse_year(tags),
          duration_ms: duration_ms(format, stream),
          format: File.extname(path).delete_prefix(".").downcase,
          extra: extra_tags(tags),
        }
```

New private methods:

```ruby
      # ID3v2.3 (TYER), v2.4 (TDRC), MP4 (©day) and Vorbis (DATE) all funnel
      # into these ffprobe tag names; the first plausible 4-digit number wins.
      def parse_year(tags)
        %w[date year tdrc tdrl originaldate].each do |key|
          match = tags[key].to_s[/\b(1\d{3}|2\d{3})\b/]
          return match.to_i if match
        end
        nil
      end

      def extra_tags(tags)
        limit = RubyPlayer::DEFAULTS["library"]["metadata_value_limit"]
        tags.each_with_object({}) do |(key, value), extras|
          next if CONSUMED_TAGS.include?(key) || value.empty?

          extras[key] = value.byteslice(0, limit).scrub
        end
      end
```

And harden `normalize_tags` (the one choke point for key/value normalization):

```ruby
      def normalize_tags(tags)
        tags.each_with_object({}) { |(key, value), h| h[key.to_s.downcase] = value.to_s.scrub }
      end
```

(`.scrub` twice is idempotent; `byteslice` can split a multibyte character, which the second scrub repairs.)

- [ ] **Step 4: Run test file + full suite** — both green.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/backends/ffmpeg.rb lib/rubyplayer/config.rb test/ffmpeg_backend_test.rb
git commit -m "feat(metadata): ffprobe album_artist/year extraction and scrubbed extra tags"
```

---

### Task 3: ExtractorPool — album fallbacks and KV persistence

**Files:**
- Modify: `lib/rubyplayer/extractor_pool.rb`
- Test: `test/extractor_pool_test.rb`

**Interfaces:**
- Consumes: Task 1's `Library#upsert_track(album_artist:, year:)` and `#replace_track_metadata`; Task 2's meta keys `:album_artist`, `:year`, `:extra` (both optional — gme/openmpt backends do not provide them).
- Produces: every upsert path bakes an album fallback when `meta[:album]` is nil:
  - plain file → parent folder basename (`File.basename(File.dirname(path))`)
  - multitrack container → container filename sans extension
  - archive entry (incl. inside multitrack-in-archive) → archive basename sans extension
  and persists `meta[:extra]` via `replace_track_metadata` when present and non-empty.

- [ ] **Step 1: Write failing tests** — read `test/extractor_pool_test.rb` first; it drives the pool with fake backends/registry. Follow its existing fake idiom and add tests:

```ruby
  def test_album_falls_back_to_parent_folder_for_plain_files
    # fake backend returning album: nil for /music/Zelda Rips/song.vgm
    # ... build per the file's existing fake-registry pattern ...
    # assert upserted album == "Zelda Rips"
  end

  def test_album_falls_back_to_container_name_for_multitrack
    # multitrack fake (track_count 2) for /music/game.nsf
    # assert both subtune rows carry album "game"
  end

  def test_explicit_album_tag_wins_over_fallback
    # fake backend returning album: "Real Album" — fallback must not clobber
  end

  def test_extra_tags_persist_to_track_metadata
    # fake backend meta includes extra: { "genre" => "VGM" }
    # assert library.track_metadata_for(track_id) == { "genre" => "VGM" }
  end

  def test_album_artist_and_year_flow_through_upsert
    # fake meta includes album_artist: "V.A.", year: 2001
    # assert Track row carries both
  end
```

These are sketches: the implementer MUST write them as real tests using the file's existing helpers (it already fakes backends for the pool; mirror that structure exactly). Archive-entry fallback is exercised implicitly by the plain/multitrack cases plus the shared helper below; if the file already has an archive fixture test, extend it with an album assertion instead of building new archive plumbing.

- [ ] **Step 2: Run, verify failures.**

- [ ] **Step 3: Implement** in `extractor_pool.rb`:

Change `upsert` to accept and apply fallback + extras:

```ruby
    def upsert(path, folder_id, subtune, backend, meta, stat, archive_entry: "",
               album_fallback: nil)
      track_id = @library.upsert_track(
        folder_id: folder_id, physical_path: path, archive_entry: archive_entry,
        subtune_index: subtune,
        backend: backend.name, format: meta[:format], title: meta[:title],
        # Fallback is baked at ingest so SQL ORDER BY, Ruby sorts, and the
        # live filter all see the same value (render-time fallback would
        # give SQL-ordered views a different order than the pane shows).
        album: meta[:album] || album_fallback,
        artist: meta[:artist], composer: meta[:composer],
        album_artist: meta[:album_artist], year: meta[:year],
        track_number: meta[:track_number], duration_ms: meta[:duration_ms],
        file_mtime: stat.mtime.to_f, file_size: stat.size
      )
      extras = meta[:extra]
      @library.replace_track_metadata(track_id, extras) if extras && !extras.empty?
      track_id
    end
```

Call sites in `extract`:

```ruby
        count.times do |i|
          upsert(item.path, folder_id, i, backend, backend.metadata(item.path, i), stat,
                 album_fallback: File.basename(item.path, ".*"))
        end
      else
        upsert(item.path, item.parent_folder_id, 0, backend,
               backend.metadata(item.path, 0), stat,
               album_fallback: File.basename(File.dirname(item.path)))
```

Call sites in `extract_entry` (both use the archive basename — the inner
entry path is noise for album purposes):

```ruby
          upsert(archive_path, sub_id, i, backend, backend.metadata(real, i), stat,
                 archive_entry: entry, album_fallback: File.basename(archive_path, ".*"))
...
        upsert(archive_path, folder_id, 0, backend, backend.metadata(real, 0), stat,
               archive_entry: entry, album_fallback: File.basename(archive_path, ".*"))
```

- [ ] **Step 4: Run test file + full suite** — both green. Watch for suite tests asserting `album` is nil for fixture scans (folder fallback now fills it) — update any such assertions to the new expected value; each such change gets a comment naming this feature.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/extractor_pool.rb test/extractor_pool_test.rb
git commit -m "feat(metadata): ingest-time album fallbacks and KV extras persistence"
```

(Include any other test files updated in Step 4.)

---

### Task 4: UI — grouping key, sort_year, info modal extras

**Files:**
- Modify: `lib/rubyplayer/ui/tracks_pane.rb` (grouping key, sort_year, album_artist preference)
- Modify: `lib/rubyplayer/keymap.rb` (tracks scope: `"e" => "sort_year"`)
- Modify: `lib/rubyplayer/ui/bottom_lines.rb` (LABELS: `sort_year: "year"`)
- Modify: `lib/rubyplayer/ui/app.rb` (info modal rows)
- Test: `test/tracks_pane_test.rb`, `test/keymap_test.rb`, `test/app_test.rb` (above `private`!)

**Interfaces:**
- Consumes: `Track#album_artist`/`#year` (Task 1), `Library#track_metadata_for` (Task 1).
- Produces:
  - `TracksPane` action `:sort_year` → sorts by `[year || 0, album, track_number]`; participates in the same disabled-in-queue/focus/playlist gates as the other sorts.
  - Grouped rows group by `[track.album_artist.to_s, track.album.to_s]`, ordered by album then album_artist; header text stays the album name. The per-group `album_artist` passed to the formatter prefers an explicit tag (majority tally of `track.album_artist`, falling back to the existing artist tally).
  - Info modal: "Album artist" and "Year" rows when present; then up to 8 KV pairs (sorted by key) from `track_metadata_for`, each as `"key: value"` with the value's first line truncated for the modal width.

- [ ] **Step 1: Write failing tests.**

`test/keymap_test.rb` — extend `test_playlist_bindings`-style coverage with:

```ruby
  def test_sort_year_binding
    map = RubyPlayer::Keymap.new({})
    assert_equal :sort_year, map.action_for("e", pane: :tracks)
    assert_nil map.action_for("e", pane: :library)
  end
```

`test/tracks_pane_test.rb` — the setup's `add` helper does not set album_artist/year; extend the helper signature with `album_artist: nil, year: nil` passing through to `upsert_track`, then:

```ruby
  def test_sort_year_orders_by_year_then_album_then_number
    # Existing setup tracks have nil year (sort as 0, first).
    add("y2.vgm", title: "New", album: "Apple", artist: "X", number: 1, year: 2001)
    add("y1.vgm", title: "Mid", album: "Apple", artist: "X", number: 1, year: 1991)
    @pane.show(@folder_row)
    @pane.handle_action(:sort_year)
    assert_equal %w[Charlie Alpha Bravo Mid New], titles
  end

  def test_grouping_separates_same_album_name_by_album_artist
    add("g1.vgm", title: "G1", album: "Hits", artist: "A", number: 1, album_artist: "ArtistOne")
    add("g2.vgm", title: "G2", album: "Hits", artist: "B", number: 1, album_artist: "ArtistTwo")
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    headers = @pane.display_rows.select { |r| r[:type] == :header }.map { |r| r[:text] }
    # Two different "Hits" albums must not merge into one group.
    assert_equal 2, headers.count("Hits")
  end
```

(Adjust `test_sort_year...` expected order after checking the setup's three
existing tracks — nil years sort first as 0, ordered `[album, number]` among
themselves: Apple/1 Bravo, Apple/2 Alpha, Zebra/1 Charlie → actually
`[0, "Apple", 2]` (Alpha), `[0, "Apple", 1]` (Bravo)… compute precisely:
nil-year tracks sort `["Apple",1]`=Bravo, `["Apple",2]`=Alpha,
`["Zebra",1]`=Charlie, then Mid (1991), New (2001). Expected:
`%w[Bravo Alpha Charlie Mid New]`. Use that.)

`test/app_test.rb` (ABOVE `private`) — info modal:

```ruby
  def test_info_modal_shows_album_artist_year_and_extras
    lib = @app.instance_variable_get(:@library)
    root = lib.upsert_folder(parent_id: nil, name: "MM", path: "/mm", kind: "dir")
    tid = lib.upsert_track(folder_id: root, physical_path: "/mm/a.mp3", backend: "ffmpeg",
                           format: "mp3", title: "A", album: "Al", artist: "Ar",
                           composer: nil, track_number: 1, duration_ms: 1000,
                           album_artist: "V.A.", year: 1998)
    lib.replace_track_metadata(tid, { "genre" => "Rock" })
    lib.recompute_counts!
    @app.library_pane.rebuild!
    track = lib.find_track(tid)
    @app.instance_variable_set(:@info_track, track)
    @app.send(:render)
    text = back_buffer_text
    assert_includes text, "Album artist: V.A."
    assert_includes text, "Year: 1998"
    assert_includes text, "genre: Rock"
  end
```

(`back_buffer_text` is an existing private helper in app_test.rb.)

- [ ] **Step 2: Run all three test files, verify failures.**

- [ ] **Step 3: Implement.**

`keymap.rb` tracks scope, extend the sort line:

```ruby
        "y" => "sort_title", "#" => "sort_number", "@" => "sort_artist",
        # "e" (yEar): "y" was already claimed by sort_title for the same
        # collision reasons documented above.
        "e" => "sort_year",
```

`bottom_lines.rb` LABELS: add `sort_year: "year",` beside the other sorts.

`tracks_pane.rb`:
- Every existing sort/group gate listing `%i[toggle_group sort_title sort_number sort_artist]` (queue/focus gate, playlist gates, the `apply_sort if` trigger list in `handle_action`) gains `:sort_year`.
- `handle_action`: `when :sort_year then @sort = :year` beside the other sorts.
- `apply_sort`: `when :year then @tracks.sort_by! { |t| [t.year || 0, t.album.to_s, t.track_number || 0] }`.
- `grouped_rows` — group key and album_artist preference:

```ruby
      def grouped_rows
        groups = filtered_tracks.group_by { |t| [t.album_artist.to_s, t.album.to_s] }
                                .sort_by { |(album_artist, album), _| [album, album_artist] }
        groups.flat_map do |(_, album), tracks|
          # An explicit album_artist tag beats the majority-artist guess —
          # that guess is why compilations used to show every artist inline.
          album_artist = tracks.filter_map(&:album_artist).tally.max_by { |_, n| n }&.first ||
                         tracks.map(&:artist).tally.max_by { |_, n| n }&.first
          [{ type: :header, text: album }] + tracks.map do |t|
            segments = TrackFormatter.render(
              @grouped_formatter, t, album_artist: album_artist, star_glyph: @star_glyph
            )
            { type: :track, text: segments.map { |segment| segment[:text] }.join,
              segments: segments, track: t }
          end
        end
      end
```

`app.rb` `render_info_modal` — after the `["Rating", ...]` row insertions, add before the Path row:

```ruby
        rows.insert(3, ["Album artist", t.album_artist]) unless t.album_artist.to_s.empty?
        rows << ["Year", t.year] if t.year
```

(Adjust: cleanest is to build the base `rows` array with the two entries
conditionally included near Album/Artist — implementer picks the insertion
that keeps label order Title/Album/Album artist/Artist/…/Year sensible.)

Then after the Status/Played rows, append KV extras:

```ruby
        extras = @library.track_metadata_for(t.id)
        extras.sort.first(INFO_METADATA_ROWS).each do |key, value|
          rows << [key, value.lines.first.to_s.chomp]
        end
```

with a class-level `INFO_METADATA_ROWS = 8` replaced by config: add to
`config.rb` DEFAULTS `"ui"`: `"info_metadata_rows" => 8` and read it via
`@config["ui", "info_metadata_rows"]` at the call site (no magic numbers).

- [ ] **Step 4: Run the three test files + full suite** — all green.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/ui/tracks_pane.rb lib/rubyplayer/keymap.rb lib/rubyplayer/ui/bottom_lines.rb lib/rubyplayer/ui/app.rb lib/rubyplayer/config.rb test/tracks_pane_test.rb test/keymap_test.rb test/app_test.rb
git commit -m "feat(metadata): album_artist grouping, year sort, info-modal extras"
```

---

## Final verification

- [ ] `bundle exec rake test` — green, run count grew vs. 406 baseline.
- [ ] README.md `library.rb`/schema blurbs still accurate (amend last commit if a one-liner).
- [ ] Note for the user: schema v3 → DB rebuild + full rescan on next launch (backup taken; playlists/ratings reset per pre-1.0 policy).
