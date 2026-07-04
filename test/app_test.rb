require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "rubyplayer/ui/app"

class AppTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @music = File.join(@tmp, "music")
    FileUtils.mkdir_p(@music)
    FileUtils.cp(File.join(FIXTURES, "space-debris.mod"), @music)
    FileUtils.cp(File.join(FIXTURES, "shantae.gbs"), @music)
    @app = RubyPlayer::UI::App.new(
      config_path: File.join(@tmp, "config.toml"),
      data_path: File.join(@tmp, "library.sqlite3"),
      null_audio: true, io_out: StringIO.new
    )
    @app.scan_paths([@music], wait: true)
  end

  def teardown
    @app.shutdown
    FileUtils.remove_entry(@tmp)
  end

  def test_scan_populates_library_and_panes
    rows = @app.library_pane.rows
    assert_equal :folder, rows[3].kind
    assert_operator rows[3].folder["track_count"], :>=, 2
  end

  def test_navigate_and_enqueue_folder
    3.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("n")                # enqueue_end the whole folder
    assert_operator @app.engine.queue_items.size, :>=, 2
  end

  def test_tab_cycles_active_pane
    assert_equal :library, @app.active_pane
    @app.handle_key("tab")
    assert_equal :tracks, @app.active_pane
  end

  def test_undo_restores_queue_and_selects_queue
    3.times { @app.handle_key("down") }
    @app.handle_key("n")
    before = @app.engine.queue_items.size
    @app.handle_key("u")
    assert_equal 0, @app.engine.queue_items.size
    assert_equal :queue, @app.library_pane.selected.kind
    @app.handle_key("ctrl_r")
    assert_equal before, @app.engine.queue_items.size
  end

  def test_add_path_mode_collects_input
    @app.handle_key("a")
    "xy".each_char { |c| @app.handle_key(c) }
    assert_equal "xy", @app.input_buffer
    @app.handle_key("escape")
    assert_nil @app.input_buffer
  end

  def test_quit_key
    @app.handle_key("ctrl_c")
    assert @app.quit?
  end

  # Bounded poll for state that changes asynchronously via the decoder
  # thread (enqueue_now/skip/seek all hand off to a command queue). Mirrors
  # the wait_for pattern already used in playback_engine_test.rb rather than
  # a blind sleep-then-assert.
  def wait_until(timeout: 2)
    deadline = Time.now + timeout
    until yield
      flunk("timed out waiting for condition") if Time.now > deadline
      sleep 0.01
    end
  end

  def test_next_track_key_advances_queue
    3.times { @app.handle_key("down") } # select the music folder (>=2 tracks)
    @app.handle_key("enter")            # play_now: enqueues the folder and starts playing
    wait_until { @app.engine.state[:track] }
    before_size = @app.engine.queue_items.size
    assert_operator before_size, :>=, 2

    @app.handle_key(">")                # next_track
    wait_until { @app.engine.queue_items.size < before_size }
    assert_equal before_size - 1, @app.engine.queue_items.size
  end

  def test_remove_from_queue_key_removes_selected_queue_track
    3.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("n")                # enqueue_end (not playing, so no auto-skip semantics)
    before_size = @app.engine.queue_items.size
    assert_operator before_size, :>=, 2

    @app.handle_key("p")                # select_queue: show the Playback Queue in tracks pane
    @app.handle_key("tab")              # focus tracks pane so nav_down routes there
    @app.handle_key("down")             # move selection onto the 2nd queue row

    @app.handle_key("x")                # remove_from_queue
    assert_equal before_size - 1, @app.engine.queue_items.size
  end

  def test_remove_from_queue_is_a_noop_outside_the_queue_view
    3.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("n")                # enqueue_end
    before_size = @app.engine.queue_items.size

    @app.handle_key("tab")              # tracks pane is showing the folder, not the queue
    @app.handle_key("x")
    assert_equal before_size, @app.engine.queue_items.size
  end

  # Regression test for the queue-index desync bug: sorting a folder view
  # left @sort "dirty" on the TracksPane instance, so switching to the
  # Playback Queue (p) redisplayed it sorted while remove_from_queue still
  # removed by raw display-row index -- silently deleting the wrong track.
  def test_sorting_a_folder_then_viewing_queue_removes_the_right_track
    library = @app.instance_variable_get(:@library)
    folder_id = library.upsert_folder(parent_id: nil, name: "synth", path: "/synth", kind: "dir")
    ids = %w[Charlie Alpha Bravo].each_with_index.map do |title, i|
      library.upsert_track(folder_id: folder_id, physical_path: "/synth/#{i}.vgm",
                           backend: "gme", format: "vgm", title: title,
                           track_number: i + 1, duration_ms: 1000)
    end
    library.recompute_counts!
    @app.library_pane.rebuild!
    tracks = ids.map { |id| library.find_track(id) }

    # Enqueue in a deliberately non-alphabetical order (Charlie, Alpha, Bravo)
    # so a leftover title sort (Alpha, Bravo, Charlie) would visibly reorder it.
    @app.engine.enqueue_end(tracks)

    folder_idx = @app.library_pane.rows.index { |r| r.kind == :folder && r.folder["name"] == "synth" }
    folder_idx.times { @app.handle_key("down") }
    @app.handle_key("tab") # focus tracks pane, which is now showing the "synth" folder
    @app.handle_key("T")   # sort_title: dirties TracksPane's @sort before we ever view the queue

    @app.handle_key("p")   # select_queue
    queue_titles = @app.tracks_pane.display_rows.map { |r| r[:track].title }
    assert_equal %w[Charlie Alpha Bravo], queue_titles

    @app.handle_key("tab") # refocus tracks pane; still showing the queue
    @app.handle_key("T")   # must be a no-op while viewing the queue
    assert_equal %w[Charlie Alpha Bravo], @app.tracks_pane.display_rows.map { |r| r[:track].title }

    @app.handle_key("down") # select queue row 1 ("Alpha")
    @app.handle_key("x")    # remove_from_queue

    assert_equal %w[Charlie Bravo], @app.engine.queue_items.map(&:title)
  end

  def test_seek_forward_key_issues_absolute_seek_without_error
    3.times { @app.handle_key("down") }
    @app.handle_key("enter")
    wait_until { @app.engine.state[:track] }

    # Stub state/seek so the assertion is exact regardless of real-time
    # playback drift on the decoder thread (position_ms ticks on wall-clock
    # time even with null audio) -- this test proves App's dispatch math
    # (absolute target = current position + configured seek step), not the
    # engine's live position at some arbitrary instant.
    engine = @app.engine
    track = engine.state[:track]
    engine.define_singleton_method(:state) do
      { track: track, playing: true, paused: false, position_ms: 5_000, skip_disliked: false }
    end
    seek_calls = []
    engine.define_singleton_method(:seek) { |ms| seek_calls << ms }

    @app.handle_key("]") # seek_forward

    assert_equal [15_000], seek_calls # 5_000 + seek_seconds(10) * 1000
  end

  def test_refresh_panes_preserves_tracks_pane_cursor
    3.times { @app.handle_key("down") } # select the music folder (populates tracks pane)
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2

    @app.handle_key("tab")              # move focus to tracks pane
    @app.handle_key("down")             # move the tracks-pane cursor off 0
    assert_equal 1, @app.tracks_pane.selection

    @app.send(:refresh_panes)           # simulate a queue_changed/track_started/track_ended event

    assert_equal 1, @app.tracks_pane.selection
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2
  end
end
