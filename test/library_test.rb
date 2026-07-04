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

  def test_history_round_trip
    id = add_track("/m/sega/a.vgm")
    @lib.record_history(track_id: id, started_at: "2026-07-04T00:00:00Z",
                        ended_at: "2026-07-04T00:01:00Z")
    h = @lib.history(limit: 10)
    assert_equal 1, h.size
    assert_equal id, h.first[:track].id
  end

  def test_rating_check_constraint
    id = add_track("/m/sega/a.vgm")
    assert_raises(SQLite3::ConstraintException) { @lib.set_rating(id, 9) }
  end
end
