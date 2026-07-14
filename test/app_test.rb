require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "rubyplayer/ui/app"

class AppTest < Minitest::Test
  class FakeFocusPlayer
    attr_reader :played, :stop_calls

    def initialize
      @played = []
      @stop_calls = 0
    end

    def play(sound)
      @played << sound
      true
    end

    def stop
      @stop_calls += 1
      true
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @music = File.join(@tmp, "music")
    FileUtils.mkdir_p(@music)
    FileUtils.cp(File.join(FIXTURES, "space-debris.mod"), @music)
    FileUtils.cp(File.join(FIXTURES, "shantae.gbs"), @music)
    @focus_player = FakeFocusPlayer.new
    @app = RubyPlayer::UI::App.new(
      config_path: File.join(@tmp, "config.toml"),
      data_path: File.join(@tmp, "library.sqlite3"),
      null_audio: true, io_out: StringIO.new, focus_player: @focus_player
    )
    @app.scan_paths([@music], wait: true)
  end

  def teardown
    @app.shutdown
    FileUtils.remove_entry(@tmp)
  end

  def test_scan_populates_library_and_panes
    rows = @app.library_pane.rows
    assert_equal :folder, rows[4].kind
    assert_operator rows[4].folder["track_count"], :>=, 2
  end

  def test_navigate_and_enqueue_folder
    4.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("n")                # enqueue_end the whole folder
    assert_operator @app.engine.queue_items.size, :>=, 2
  end

  def test_enqueue_from_tracks_pane_puts_a_track_in_the_queue
    # Regression: Array(struct) used to splat the Track into its field values,
    # enqueuing the Integer id instead of the Track (crashed the decoder thread
    # on track.physical_path). The queue must hold Track objects.
    4.times { @app.handle_key("down") } # select the music folder in library pane
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

  def test_tab_cycles_active_pane
    assert_equal :library, @app.active_pane
    @app.handle_key("tab")
    assert_equal :tracks, @app.active_pane
  end

  def test_undo_restores_queue_and_selects_queue
    4.times { @app.handle_key("down") }
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

  def select_tracks_for(kind)
    @app.instance_variable_set(:@active_pane, :library)
    20.times { @app.handle_key("up") }
    index = @app.library_pane.rows.index { |row| row.kind == kind }
    index.times { @app.handle_key("down") }
    @app.handle_key("tab")
  end

  def start_normal_playback
    select_tracks_for(:folder)
    @app.handle_key("enter")
    wait_until { @app.engine.state[:playing] }
  end

  def test_focus_enter_stops_queue_playback_and_keeps_queue
    start_normal_playback
    queued_ids = @app.engine.queue_items.map(&:id)
    select_tracks_for(:focus)

    playing_when_focus_started = nil
    engine = @app.engine
    focus_player = FakeFocusPlayer.new
    focus_player.define_singleton_method(:play) do |sound|
      playing_when_focus_started = engine.state[:playing]
      super(sound)
    end
    @app.instance_variable_set(:@focus_player, focus_player)

    @app.handle_key("enter")

    refute playing_when_focus_started,
      "decoder playback must stop before Focus starts writing to shared audio"
    assert_equal [RubyPlayer::FocusSounds::ALL.first], focus_player.played
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
    4.times { @app.handle_key("down") } # select the music folder (>=2 tracks)
    @app.handle_key("enter")            # play_now: enqueues the folder and starts playing
    wait_until { @app.engine.state[:track] }
    before_size = @app.engine.queue_items.size
    assert_operator before_size, :>=, 2

    @app.handle_key(">")                # next_track
    wait_until { @app.engine.queue_items.size < before_size }
    assert_equal before_size - 1, @app.engine.queue_items.size
  end

  def test_remove_from_queue_key_removes_selected_queue_track
    4.times { @app.handle_key("down") } # select the music folder
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
    4.times { @app.handle_key("down") } # select the music folder
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

  def test_remove_library_item_key_prompts_confirmation_without_removing
    4.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("x")
    refute_nil @app.pending_delete
    assert_equal "music", @app.pending_delete["name"]
    refute_empty @app.library_pane.rows.select { |r| r.kind == :folder }
  end

  def test_remove_library_item_is_a_noop_on_special_rows
    @app.handle_key("x") # selection starts on the Playback Queue row
    assert_nil @app.pending_delete
  end

  def test_confirm_removes_the_folder_from_the_library
    4.times { @app.handle_key("down") }
    @app.handle_key("x")
    @app.handle_key("y")
    assert_nil @app.pending_delete
    assert_empty @app.library_pane.rows.select { |r| r.kind == :folder }
  end

  def test_cancel_leaves_the_library_untouched
    4.times { @app.handle_key("down") }
    @app.handle_key("x")
    @app.handle_key("escape")
    assert_nil @app.pending_delete
    refute_empty @app.library_pane.rows.select { |r| r.kind == :folder }
  end

  # Regression target: the playback queue holds Track objects independent of
  # the DB (see test_enqueue_from_tracks_pane_puts_a_track_in_the_queue), so
  # a soft-delete in Library alone would leave the deleted folder's tracks
  # stranded in the queue. Confirming a delete must cascade into the queue.
  def test_confirm_cascades_the_delete_into_a_queued_folder
    4.times { @app.handle_key("down") }
    @app.handle_key("n") # enqueue_end the whole folder (not playing)
    assert_operator @app.engine.queue_items.size, :>=, 2

    @app.handle_key("x")
    @app.handle_key("y")

    assert_equal 0, @app.engine.queue_items.size
  end

  def test_confirm_stops_playback_when_the_playing_track_is_deleted
    4.times { @app.handle_key("down") }
    @app.handle_key("enter") # play_now: enqueues the folder and starts playing
    wait_until { @app.engine.state[:track] }

    @app.handle_key("x")
    @app.handle_key("y")

    wait_until { @app.engine.queue_items.empty? }
  end

  def test_show_track_info_key_populates_info_track
    4.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("tab")              # focus the Tracks pane
    @app.handle_key("i")
    assert_instance_of RubyPlayer::Track, @app.info_track
  end

  def test_show_track_info_key_is_a_noop_in_the_library_pane
    @app.handle_key("i") # library pane active: "i" isn't bound there
    assert_nil @app.info_track
  end

  def test_escape_dismisses_the_track_info_modal
    4.times { @app.handle_key("down") }
    @app.handle_key("tab")
    @app.handle_key("i")
    @app.handle_key("escape")
    assert_nil @app.info_track
  end

  def test_help_key_opens_and_escape_closes_the_modal
    @app.handle_key("?")
    assert @app.show_help
    @app.handle_key("escape")
    refute @app.show_help
  end

  def test_help_modal_lists_bindings_for_the_active_pane
    @app.handle_key("?")
    @app.render
    out = @app.instance_variable_get(:@io_out).string
    assert_includes out, "Hotkeys (library)"
    assert_includes out, "SPACE"
  end

  def test_help_modal_lays_out_bindings_in_two_columns
    @app.handle_key("?")
    @app.render
    screen = @app.instance_variable_get(:@screen)
    back = screen.instance_variable_get(:@back)

    keymap = @app.instance_variable_get(:@keymap)
    bindings = keymap.bindings_for(:library)
    rows = (bindings.size / 2.0).ceil
    assert_operator bindings.size, :>, rows # otherwise there's no 2nd column to prove

    first_key = bindings.first.first.upcase
    second_col_key = bindings[rows].first.upcase
    row_with_first_key = back.map { |r| r.map(&:ch).join }.find { |line| line.include?(first_key) }
    refute_nil row_with_first_key
    assert_includes row_with_first_key, second_col_key
  end

  def test_starts_on_the_default_theme
    assert_equal :default, @app.theme_id
  end

  def test_theme_picker_key_opens_the_modal
    @app.handle_key("t")
    assert @app.theme_picker
  end

  def test_scrolling_the_theme_picker_previews_immediately
    @app.handle_key("t")
    before = @app.theme_id
    @app.handle_key("down")
    refute_equal before, @app.theme_id # live preview changed the active theme
    assert @app.theme_picker # still open -- nothing persisted yet
    assert_equal "default", @app.instance_variable_get(:@config)["ui", "theme"]
  end

  def test_confirming_the_theme_picker_persists_the_previewed_theme
    @app.handle_key("t")
    @app.handle_key("down")
    previewed = @app.theme_id
    @app.handle_key("enter")

    refute @app.theme_picker
    assert_equal previewed, @app.theme_id
    assert_equal previewed.to_s, @app.instance_variable_get(:@config)["ui", "theme"]
  end

  def test_cancelling_the_theme_picker_reverts_the_preview
    @app.handle_key("t")
    @app.handle_key("down")
    refute_equal :default, @app.theme_id
    @app.handle_key("escape")

    refute @app.theme_picker
    assert_equal :default, @app.theme_id
  end

  def test_selecting_a_hex_theme_actually_changes_rendered_colors
    @app.render
    # StringIO#string returns the live internal buffer, not a copy -- capture
    # the length now (an Integer, immune to later mutation) rather than the
    # string object itself, or "before" would grow along with "after".
    before_len = @app.instance_variable_get(:@io_out).string.size

    @app.handle_key("t")
    @app.handle_key("down") # preview the first named (hex) theme
    @app.render
    themed_out = @app.instance_variable_get(:@io_out).string[before_len..]

    border_hex = RubyPlayer::Theme[@app.theme_id][:border_focus].delete("#").scan(/../).map { |h| h.to_i(16) }
    assert_includes themed_out, "38;2;#{border_hex.join(';')}m"
  end

  def test_theme_picker_wraps_around_the_list
    @app.handle_key("t")
    @app.handle_key("up") # one before :default wraps to the last theme
    assert_equal RubyPlayer::Theme::ALL_IDS.last, @app.theme_id
  end

  def test_seek_forward_key_issues_absolute_seek_without_error
    4.times { @app.handle_key("down") }
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
    4.times { @app.handle_key("down") } # select the music folder (populates tracks pane)
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2

    @app.handle_key("tab")              # move focus to tracks pane
    @app.handle_key("down")             # move the tracks-pane cursor off 0
    assert_equal 1, @app.tracks_pane.selection

    @app.send(:refresh_panes)           # simulate a queue_changed/track_started/track_ended event

    assert_equal 1, @app.tracks_pane.selection
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2
  end
end
