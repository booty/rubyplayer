require "test_helper"
require "tmpdir"

class TracksPaneTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @folder = @lib.upsert_folder(parent_id: nil, name: "m", path: "/m", kind: "dir")
    add("c.vgm", title: "Charlie", album: "Zebra", artist: "X", number: 1)
    add("a.vgm", title: "Alpha",   album: "Apple", artist: "X", number: 2)
    add("b.vgm", title: "Bravo",   album: "Apple", artist: "Y", number: 1)
    @lib.recompute_counts!
    @config = RubyPlayer::ConfigStore.new(path: "/nonexistent.toml")
    @queue = []
    @pane = RubyPlayer::UI::TracksPane.new(library: @lib, config: @config,
                                           queue_source: -> { @queue })
    @folder_row = RubyPlayer::UI::LibraryPane::Row.new(
      kind: :folder, folder: { "id" => @folder }, depth: 0
    )
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  def add(file, title:, album:, artist:, number:)
    @lib.upsert_track(folder_id: @folder, physical_path: "/m/#{file}",
                      backend: "gme", format: "vgm", title: title, album: album,
                      artist: artist, track_number: number, duration_ms: 60_000)
  end

  def titles = @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].title }

  def test_folder_view_lists_tracks
    @pane.show(@folder_row)
    assert_equal 3, titles.size
  end

  def test_sorting
    @pane.show(@folder_row)
    @pane.handle_action(:sort_title)
    assert_equal %w[Alpha Bravo Charlie], titles
    @pane.handle_action(:sort_artist)
    assert_equal %w[X X Y].sort, @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].artist }.sort
    @pane.handle_action(:sort_number)
    assert_equal [1, 1, 2].sort, @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].track_number }.sort
  end

  def test_grouping_inserts_album_headers_sorted_by_album
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    rows = @pane.display_rows
    headers = rows.select { |r| r[:type] == :header }.map { |r| r[:text] }
    assert_equal %w[Apple Zebra], headers
    assert_equal :header, rows.first[:type]
  end

  def test_grouped_template_hides_artist_matching_album_artist
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    apple_rows = @pane.display_rows.select { |r| r[:type] == :track && r[:track].album == "Apple" }
    x_row = apple_rows.find { |r| r[:track].artist == "X" } # X is Apple's dominant artist
    y_row = apple_rows.find { |r| r[:track].artist == "Y" }
    refute_includes x_row[:text], "X"
    assert_includes y_row[:text], "Y"
  end

  def test_selection_skips_headers
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    assert_equal :track, @pane.display_rows[@pane.selection][:type]
    refute_nil @pane.selected_track
  end

  def test_queue_view_uses_queue_source
    @queue = [@lib.find_track(@lib.upsert_track(
      folder_id: @folder, physical_path: "/m/q.vgm", backend: "gme",
      format: "vgm", title: "Queued"
    ))]
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))
    assert_equal %w[Queued], titles
  end

  # Regression test for the queue-index desync bug: TracksPane used to keep
  # @sort/@group_by_album across show(), so switching to the Playback Queue
  # after sorting/grouping a folder view left the queue displayed out of
  # playback order while selected_track_index (used by App#remove_from_queue
  # to call engine.remove_at) still assumed row-position == queue-position.
  def test_queue_view_ignores_prior_sort_and_group
    folder_tracks = @lib.tracks_under(@folder)
    charlie = folder_tracks.find { |t| t.title == "Charlie" }
    alpha   = folder_tracks.find { |t| t.title == "Alpha" }
    bravo   = folder_tracks.find { |t| t.title == "Bravo" }
    # Deliberately not title-, number-, or artist-sorted order, so any
    # leftover sort/group would visibly reorder this list.
    @queue = [charlie, alpha, bravo]

    # Dirty @sort/@group_by_album on a folder view BEFORE ever showing the queue.
    @pane.show(@folder_row)
    @pane.handle_action(:sort_title)
    @pane.handle_action(:toggle_group)

    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))

    # (a) display order is the true queue/playback order, not the stale sort
    # (title sort would read Alpha, Bravo, Charlie) and not grouped (no headers).
    assert_equal %w[Charlie Alpha Bravo], titles
    refute(@pane.display_rows.any? { |r| r[:type] == :header })

    # (b) sort/group keys must be no-ops while viewing the queue, so the user
    # can't re-introduce the desync from inside the queue view itself.
    @pane.handle_action(:toggle_group)
    @pane.handle_action(:sort_title)
    @pane.handle_action(:sort_number)
    @pane.handle_action(:sort_artist)
    assert_equal %w[Charlie Alpha Bravo], titles

    # (c) selected_track_index must be the real queue position of the
    # selected row (not just "some index") -- that's the value App passes
    # straight to engine.remove_at.
    @pane.handle_action(:nav_down) # move onto queue row 1
    assert_equal 1, @pane.selected_track_index
    assert_equal "Alpha", @pane.selected_track.title
  end

  def test_config_hot_reload_changes_format
    @pane.show(@folder_row)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "c.toml")
      File.write(path, "[ui]\nformat_string_ungrouped = \"<<{title}>>\"\n")
      @pane.update_config(RubyPlayer::ConfigStore.new(path: path))
      assert_includes @pane.display_rows.first[:text], "<<"
    end
  end
end
