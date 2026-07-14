require "test_helper"
require "tmpdir"

class LibraryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@dir, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @root = @lib.upsert_folder(parent_id: nil, name: "Music", path: "/m", kind: "dir")
    @sub = @lib.upsert_folder(parent_id: @root, name: "Sega", path: "/m/sega", kind: "dir")
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@dir)
  end

  def add_track(path, folder: @sub, subtune: 0, title: "T", rating: nil)
    id = @lib.upsert_track(folder_id: folder, physical_path: path, subtune_index: subtune,
                           backend: "gme", format: "vgm", title: title, album: "A",
                           artist: "Ar", composer: "C", track_number: 1, duration_ms: 60_000)
    @lib.set_rating(id, rating) if rating
    id
  end

  def test_upsert_folder_is_idempotent_on_path
    id2 = @lib.upsert_folder(parent_id: nil, name: "Music", path: "/m", kind: "dir")
    assert_equal @root, id2
  end

  def test_upsert_track_idempotent_and_preserves_rating
    id = add_track("/m/sega/a.vgm")
    @lib.set_rating(id, 5)
    id2 = @lib.upsert_track(folder_id: @sub, physical_path: "/m/sega/a.vgm",
                            backend: "gme", format: "vgm", title: "New Title",
                            album: "A", artist: "Ar", composer: "C",
                            track_number: 1, duration_ms: 61_000)
    assert_equal id, id2
    t = @lib.find_track(id)
    assert_equal "New Title", t.title
    assert_equal 5, t.rating
  end

  def test_subtunes_are_distinct_tracks
    a = add_track("/m/sega/multi.nsf", subtune: 0)
    b = add_track("/m/sega/multi.nsf", subtune: 1)
    refute_equal a, b
  end

  def test_tracks_under_is_recursive_and_skips_missing
    add_track("/m/sega/a.vgm")
    missing_id = add_track("/m/sega/gone.vgm")
    @lib.mark_missing(track_ids: [missing_id], folder_ids: [])
    tracks = @lib.tracks_under(@root)
    assert_equal ["/m/sega/a.vgm"], tracks.map(&:physical_path)
  end

  def test_recompute_counts_and_root_visibility
    assert_empty @lib.roots # zero tracks -> hidden
    add_track("/m/sega/a.vgm")
    @lib.recompute_counts!
    roots = @lib.roots
    assert_equal 1, roots.size
    assert_equal 1, roots.first["track_count"]
  end

  def test_favorites
    add_track("/m/sega/a.vgm", rating: 5)
    add_track("/m/sega/b.vgm", rating: 2)
    assert_equal ["/m/sega/a.vgm"], @lib.favorites.map(&:physical_path)
  end

  def test_recently_added_excludes_missing_and_orders_newest_first
    old_id = add_track("/m/sega/old.vgm", title: "Old")
    new_id = add_track("/m/sega/new.vgm", title: "New")
    missing_id = add_track("/m/sega/missing.vgm", title: "Missing")
    @db.write do |db|
      db.execute("UPDATE tracks SET added_at = ? WHERE id = ?", ["2026-01-01T00:00:00Z", old_id])
      db.execute("UPDATE tracks SET added_at = ? WHERE id = ?", ["2026-02-01T00:00:00Z", new_id])
    end
    @lib.mark_missing(track_ids: [missing_id], folder_ids: [])

    assert_equal %w[New Old], @lib.recently_added.map(&:title)
  end

  def test_unrated_excludes_rated_and_missing_tracks
    unrated_id = add_track("/m/sega/unrated.vgm", title: "Unrated")
    add_track("/m/sega/rated.vgm", title: "Rated", rating: 4)
    missing_id = add_track("/m/sega/missing.vgm", title: "Missing")
    @lib.mark_missing(track_ids: [missing_id], folder_ids: [])

    assert_equal [unrated_id], @lib.unrated.map(&:id)
  end

  def test_missing_tracks_order_by_path_then_title
    z_id = add_track("/m/sega/z.vgm", title: "Zed")
    a_id = add_track("/m/sega/a.vgm", title: "Alpha")
    add_track("/m/sega/live.vgm", title: "Live")
    @lib.mark_missing(track_ids: [z_id, a_id], folder_ids: [])

    assert_equal %w[Alpha Zed], @lib.missing_tracks.map(&:title)
  end

  def test_failed_tracks_include_missing_failures
    failed_id = add_track("/m/sega/failed.vgm", title: "Failed")
    missing_failed_id = add_track("/m/sega/gone.vgm", title: "Gone")
    healthy_id = add_track("/m/sega/healthy.vgm", title: "Healthy")
    @lib.set_errored(failed_id)
    @lib.set_errored(missing_failed_id)
    @lib.mark_missing(track_ids: [missing_failed_id], folder_ids: [])

    assert_equal [failed_id, missing_failed_id].sort, @lib.failed_tracks.map(&:id).sort
    refute_includes @lib.failed_tracks.map(&:id), healthy_id
  end

  def test_purge_missing_tracks_deletes_only_missing_rows_and_history
    missing_id = add_track("/m/sega/gone.vgm", title: "Gone")
    healthy_id = add_track("/m/sega/live.vgm", title: "Live")
    @lib.record_history(track_id: missing_id, started_at: "2026-07-01T00:00:00Z",
                        ended_at: "2026-07-01T00:01:00Z")
    @lib.record_history(track_id: healthy_id, started_at: "2026-07-01T00:00:00Z",
                        ended_at: "2026-07-01T00:01:00Z")
    @lib.mark_missing(track_ids: [missing_id], folder_ids: [])

    deleted = @lib.purge_missing_tracks!([missing_id, healthy_id])

    assert_equal [missing_id], deleted
    assert_nil @lib.find_track(missing_id)
    refute_nil @lib.find_track(healthy_id)
    history_ids = @db.read { |db| db.execute("SELECT track_id FROM playback_history").map { |row| row["track_id"] } }
    assert_equal [healthy_id], history_ids
  end

  def test_most_played_orders_by_count_then_total_duration_and_excludes_missing
    most_id = add_track("/m/sega/most.vgm", title: "Most")
    long_id = add_track("/m/sega/long.vgm", title: "Long")
    short_id = add_track("/m/sega/short.vgm", title: "Short")
    missing_id = add_track("/m/sega/missing.vgm", title: "Missing")
    3.times { |i| record_play(most_id, day: i + 1, seconds: 10) }
    2.times { |i| record_play(long_id, day: i + 1, seconds: 30) }
    2.times { |i| record_play(short_id, day: i + 1, seconds: 5) }
    4.times { |i| record_play(missing_id, day: i + 1, seconds: 60) }
    @lib.mark_missing(track_ids: [missing_id], folder_ids: [])

    assert_equal %w[Most Long Short], @lib.most_played.map(&:title)
  end

  def test_history_round_trip
    id = add_track("/m/sega/a.vgm")
    @lib.record_history(track_id: id, started_at: "2026-07-04T00:00:00Z",
                        ended_at: "2026-07-04T00:01:00Z")
    h = @lib.history(limit: 10)
    assert_equal 1, h.size
    assert_equal id, h.first[:track].id
  end

  # Regression-target for the library-item-removal feature: removing a
  # folder must soft-delete its whole subtree (not just direct children) and
  # hand back every affected track id so the caller can cascade the removal
  # into the live playback queue, which the DB knows nothing about.
  def test_remove_folder_marks_subtree_missing_and_returns_track_ids
    id1 = add_track("/m/sega/a.vgm")
    id2 = add_track("/m/sega/b.vgm", rating: 5)

    removed = @lib.remove_folder!(@sub)

    assert_equal [id1, id2].sort, removed.sort
    assert_empty @lib.tracks_under(@root)
    assert_empty @lib.favorites
    assert_empty @lib.children_of(@root) # @sub is now hidden (missing)
  end

  def test_remove_folder_recurses_into_subfolders
    grandchild = @lib.upsert_folder(parent_id: @sub, name: "Deep", path: "/m/sega/deep", kind: "dir")
    deep_id = add_track("/m/sega/deep/c.vgm", folder: grandchild)

    removed = @lib.remove_folder!(@root)

    assert_includes removed, deep_id
    assert_empty @lib.tracks_under(@root)
  end

  def test_play_stats_aggregates_count_total_and_last_played
    id = add_track("/m/sega/a.vgm")
    assert_equal({ count: 0, last_played_at: nil, total_played_ms: 0 }, @lib.play_stats(id))

    @lib.record_history(track_id: id, started_at: "2026-07-01T00:00:00Z", ended_at: "2026-07-01T00:01:00Z")
    @lib.record_history(track_id: id, started_at: "2026-07-02T00:00:00Z", ended_at: "2026-07-02T00:00:30Z")
    stats = @lib.play_stats(id)

    assert_equal 2, stats[:count]
    assert_equal 90_000, stats[:total_played_ms]
    assert_equal "2026-07-02T00:00:00Z", stats[:last_played_at]
  end

  def test_rating_check_constraint
    id = add_track("/m/sega/a.vgm")
    assert_raises(SQLite3::ConstraintException) { @lib.set_rating(id, 9) }
  end


  private

  def record_play(track_id, day:, seconds:)
    started = Time.utc(2026, 1, day, 0, 0, 0)
    @lib.record_history(track_id: track_id, started_at: started.iso8601,
                        ended_at: (started + seconds).iso8601)
  end
end
