require "test_helper"
require_relative "support/app_test_support"

class AppPlaybackQueueTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_smart_view_displays_normal_playable_tracks
    select_tracks_for(:recent)

    assert_instance_of RubyPlayer::Track, @app.tracks_pane.selected_track
    @app.handle_key("enter")

    refute_empty @app.engine.queue_items
  end

  def test_navigate_and_enqueue_folder
    select_library_kind(:folder)
    @app.handle_key("n")                # enqueue_end the whole folder
    assert_operator @app.engine.queue_items.size, :>=, 2
  end

  def test_enqueue_all_songs_adds_every_present_track
    expected_ids = @app.instance_variable_get(:@library).all_tracks.map(&:id)
    select_library_kind(:all)

    @app.handle_key("n")

    assert_equal expected_ids, @app.engine.queue_items.map(&:id)
  end

  def test_enqueue_from_tracks_pane_puts_a_track_in_the_queue
    # Regression: Array(struct) used to splat the Track into its field values,
    # enqueuing the Integer id instead of the Track (crashed the decoder thread
    # on track.physical_path). The queue must hold Track objects.
    select_library_kind(:folder)
    @app.handle_key("right")            # expand (harmless if leaf) then...
    @app.handle_key("tab")              # focus the Tracks pane
    assert_equal :tracks, @app.active_pane
    refute_nil @app.tracks_pane.selected_track, "tracks pane should have a selected track"
    @app.handle_key("enter")            # play now
    refute_empty @app.engine.queue_items
    @app.engine.queue_items.each do |item|
      assert_instance_of RubyPlayer::Track, item,
        "queue must hold Track objects, got #{item.class}: #{item.inspect}"
    end
  end

  def test_undo_restores_queue_and_selects_queue
    select_library_kind(:folder)
    @app.handle_key("n")
    before = @app.engine.queue_items.size
    @app.handle_key("u")
    assert_equal 0, @app.engine.queue_items.size
    assert_equal :queue, @app.library_pane.selected.kind
    @app.handle_key("ctrl_r")
    assert_equal before, @app.engine.queue_items.size
  end

  def test_shutdown_closes_every_resource_when_focus_stop_fails
    cleanup_calls = []
    engine_shutdown = @app.engine.method(:shutdown)
    audio = @app.instance_variable_get(:@audio)
    audio_close = audio.method(:close)
    database = @app.instance_variable_get(:@db)
    database_close = database.method(:close)

    @app.engine.play_focus(RubyPlayer::FocusSounds::ALL.first)
    @focus_player.stop_error = RubyPlayer::FocusPlayer::Error.new("focus cleanup failed")
    @app.engine.define_singleton_method(:shutdown) do
      cleanup_calls << :engine
      engine_shutdown.call
    end
    audio.define_singleton_method(:close) do
      cleanup_calls << :audio
      audio_close.call
    end
    database.define_singleton_method(:close) do
      cleanup_calls << :database
      database_close.call
    end

    error = assert_raises(RubyPlayer::FocusPlayer::Error) { @app.shutdown }

    assert_equal "focus cleanup failed", error.message
    assert_equal %i[engine audio database], cleanup_calls
  ensure
    @focus_player.stop_error = nil
  end

  def test_focus_enter_stops_queue_playback_and_keeps_queue
    start_normal_playback
    queued_ids = @app.engine.queue_items.map(&:id)
    select_tracks_for(:focus)

    playing_when_focus_started = nil
    engine = @app.engine
    @focus_player.before_play = lambda do
      playing_when_focus_started = engine.state[:playing]
    end

    @app.handle_key("enter")

    refute playing_when_focus_started,
      "decoder playback must stop before Focus starts writing to shared audio"
    assert_equal [RubyPlayer::FocusSounds::ALL.first], @focus_player.played
    assert_equal queued_ids, @app.engine.queue_items.map(&:id)
  end

  def test_normal_playback_stops_focus
    select_tracks_for(:focus)
    @app.handle_key("enter")
    select_tracks_for(:folder)

    @app.handle_key("enter")

    assert_operator @focus_player.stop_calls, :>=, 1
  end

  def test_focus_cannot_be_queued
    select_tracks_for(:focus)
    before = @app.engine.queue_items

    @app.handle_key("q")
    @app.render
    assert_equal before, @app.engine.queue_items
    assert_includes @app.instance_variable_get(:@io_out).string, "Focus sounds cannot be queued"

    @app.handle_key("n")
    assert_equal before, @app.engine.queue_items
  end

  def test_next_track_key_advances_queue
    select_library_kind(:folder)
    @app.handle_key("enter")            # play_now: enqueues the folder and starts playing
    wait_until(timeout: 2, interval: 0.01, failure_message: "timed out waiting for condition") { @app.engine.state[:track] }
    before_size = @app.engine.queue_items.size
    assert_operator before_size, :>=, 2

    @app.handle_key(">")                # next_track
    wait_until(timeout: 2, interval: 0.01, failure_message: "timed out waiting for condition") { @app.engine.queue_items.size < before_size }
    assert_equal before_size - 1, @app.engine.queue_items.size
  end

  def test_remove_from_queue_key_removes_selected_queue_track
    select_library_kind(:folder)
    @app.handle_key("n")                # enqueue_end (not playing, so no auto-skip semantics)
    before_size = @app.engine.queue_items.size
    assert_operator before_size, :>=, 2

    @app.handle_key("p")                # select_queue: show the Playback Queue in tracks pane
    @app.handle_key("tab")              # focus tracks pane so nav_down routes there
    @app.handle_key("down")             # move selection onto the 2nd queue row

    @app.handle_key("x")                # remove_from_queue
    assert_equal before_size - 1, @app.engine.queue_items.size
  end

  def test_remove_from_filtered_queue_removes_visible_track
    select_library_kind(:folder)
    @app.handle_key("n")
    target = @app.engine.queue_items.find { |track| track.title == "space_debris" }
    @app.handle_key("p")
    @app.handle_key("tab")
    @app.tracks_pane.filter = "space"

    @app.handle_key("x")

    refute_includes @app.engine.queue_items.map(&:id), target.id
  end

  def test_remove_from_queue_is_a_noop_outside_the_queue_view
    select_library_kind(:folder)
    @app.handle_key("n")                # enqueue_end
    before_size = @app.engine.queue_items.size

    @app.handle_key("tab")              # tracks pane is showing the folder, not the queue
    @app.handle_key("x")
    assert_equal before_size, @app.engine.queue_items.size
  end

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
    @app.handle_key("Y")   # sort_title: dirties TracksPane's @sort before we ever view the queue

    @app.handle_key("p")   # select_queue
    queue_titles = @app.tracks_pane.display_rows.map { |r| r[:track].title }
    assert_equal %w[Charlie Alpha Bravo], queue_titles

    @app.handle_key("tab") # refocus tracks pane; still showing the queue
    @app.handle_key("Y")   # must be a no-op while viewing the queue
    assert_equal %w[Charlie Alpha Bravo], @app.tracks_pane.display_rows.map { |r| r[:track].title }

    @app.handle_key("down") # select queue row 1 ("Alpha")
    @app.handle_key("x")    # remove_from_queue

    assert_equal %w[Charlie Bravo], @app.engine.queue_items.map(&:title)
  end

  def test_seek_forward_key_issues_absolute_seek_without_error
    select_library_kind(:folder)
    @app.handle_key("enter")
    wait_until(timeout: 2, interval: 0.01, failure_message: "timed out waiting for condition") { @app.engine.state[:track] }

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
end
