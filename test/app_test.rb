require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "rubyplayer/ui/app"

class AppTest < Minitest::Test
  class FakeFocusPlayer
    attr_reader :played, :stop_calls
    attr_accessor :before_play, :stop_error

    def initialize
      @played = []
      @stop_calls = 0
      @playing = false
    end

    def play(sound, sample_rate:)
      @before_play&.call
      @played << sound
      @playing = true
      true
    end

    def read(frames)
      return nil unless @playing

      ([0.0] * frames * RubyPlayer::AudioFormat::CHANNELS).pack("e*")
    end

    def stop
      raise @stop_error if @stop_error

      @stop_calls += 1
      @playing = false
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
    @app = make_app
    @app.scan_paths([@music], wait: true)
  end

  # env defaults to iTerm2 so art tests exercise the emission path;
  # everything else ignores it.
  def make_app(env: { "TERM_PROGRAM" => "iTerm.app" }, config_path: File.join(@tmp, "config.rb"))
    RubyPlayer::UI::App.new(
      config_path: config_path,
      data_path: File.join(@tmp, "library.sqlite3"),
      null_audio: true, io_out: StringIO.new, focus_player: @focus_player,
      env: env
    )
  end

  def teardown
    @app&.shutdown
    FileUtils.remove_entry(@tmp)
  end

  def test_scan_populates_library_and_panes
    rows = @app.library_pane.rows
    folder = rows.find { |row| row.kind == :folder }
    assert_operator folder.folder["track_count"], :>=, 2
  end


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

  def test_selecting_all_songs_displays_every_present_track
    expected_ids = @app.instance_variable_get(:@library).all_tracks.map(&:id)

    select_tracks_for(:all)

    assert_equal expected_ids, @app.tracks_pane.visible_tracks.map(&:id)
    assert_equal "All Songs · #{expected_ids.size}", @app.tracks_pane.title
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

  def test_tab_cycles_active_pane
    assert_equal :library, @app.active_pane
    @app.handle_key("tab")
    assert_equal :tracks, @app.active_pane
  end

  def test_narrow_layout_renders_only_active_pane
    out = StringIO.new
    @app.instance_variable_set(:@io_out, out)
    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: 20, cols: 71))

    @app.render
    library_frame = @app.instance_variable_get(:@screen).instance_variable_get(:@back)
    assert_includes library_frame[0].map(&:ch).join, "Library"
    refute_includes library_frame[0].map(&:ch).join, "Playback Queue"

    @app.handle_key("tab")
    @app.render
    tracks_frame = @app.instance_variable_get(:@screen).instance_variable_get(:@back)
    assert_includes tracks_frame[0].map(&:ch).join, "Playback Queue · 0"
    refute_includes tracks_frame[0].map(&:ch).join, "Library"
  end

  def test_two_pane_layout_starts_at_72_columns
    out = StringIO.new
    @app.instance_variable_set(:@io_out, out)
    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: 20, cols: 72))

    @app.render
    title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join

    assert_includes title_row, "Library"
    assert_includes title_row, "Playback Queue · 0"
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

  def test_add_path_mode_collects_input
    @app.handle_key("a")
    "xy".each_char { |c| @app.handle_key(c) }
    assert_equal "xy", @app.input_buffer
    @app.handle_key("escape")
    assert_nil @app.input_buffer
  end

  def test_dropped_folder_scans_pasted_path_without_opening_filter
    scans = []
    @app.define_singleton_method(:scan_paths) { |paths, **| scans << paths }

    bytes = "\e[200~#{@tmp}/My\\ Music\e[201~"
    RubyPlayer::UI::KeyDecoder.decode(bytes).each { |event| @app.handle_key(event) }

    assert_equal [[File.join(@tmp, "My Music")]], scans
    assert_nil @app.filter_buffer
  end

  def test_plain_slash_still_opens_filter
    @app.handle_key("/")

    assert_equal "", @app.filter_buffer
  end

  def test_filter_mode_updates_live_and_enter_accepts
    select_tracks_for(:folder)

    @app.handle_key("/")
    "space".each_char { |char| @app.handle_key(char) }

    assert_equal "space", @app.filter_buffer
    assert_equal ["space_debris"], @app.tracks_pane.display_rows.map { |row| row[:track].title }
    @app.handle_key("enter")
    assert_nil @app.filter_buffer
    assert_equal "space", @app.tracks_pane.filter
  end

  def test_filter_escape_restores_previous_filter
    select_tracks_for(:folder)
    @app.tracks_pane.filter = "space"

    @app.handle_key("/")
    @app.handle_key("backspace")
    @app.handle_key("escape")

    assert_nil @app.filter_buffer
    assert_equal "space", @app.tracks_pane.filter
  end

  def test_submitting_empty_filter_clears_existing_filter
    select_tracks_for(:folder)
    @app.tracks_pane.filter = "space"

    @app.handle_key("/")
    5.times { @app.handle_key("backspace") }
    @app.handle_key("enter")

    assert_equal "", @app.tracks_pane.filter
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2
  end

  def test_quit_key
    @app.handle_key("ctrl_c")
    assert @app.quit?
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

  # Bounded poll for state that changes asynchronously via the decoder
  # thread (enqueue_now/skip/seek all hand off to a command queue). Mirrors
  # the wait_for pattern already used in playback_engine_test.rb rather than
  # a blind sleep-then-assert.
  def wait_until(timeout: 2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk("timed out waiting for condition") if now > deadline
      sleep 0.01
    end
  end

  def select_tracks_for(kind)
    select_library_kind(kind)
    @app.handle_key("tab")
  end

  def select_library_kind(kind)
    @app.instance_variable_set(:@active_pane, :library)
    20.times { @app.handle_key("up") }
    index = @app.library_pane.rows.index { |row| row.kind == kind }
    index.times { @app.handle_key("down") }
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
    wait_until { @app.engine.state[:track] }
    before_size = @app.engine.queue_items.size
    assert_operator before_size, :>=, 2

    @app.handle_key(">")                # next_track
    wait_until { @app.engine.queue_items.size < before_size }
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
    select_library_kind(:folder)
    @app.handle_key("x")
    refute_nil @app.pending_delete
    assert_equal "music", @app.pending_delete["name"]
    refute_empty @app.library_pane.rows.select { |r| r.kind == :folder }
  end

  def test_remove_library_item_is_a_noop_on_special_rows
    @app.handle_key("x") # selection starts on the Playback Queue row
    assert_nil @app.pending_delete
  end

  def test_remove_library_item_is_a_noop_on_all_songs
    select_library_kind(:all)

    @app.handle_key("x")

    assert_nil @app.pending_delete
  end

  def test_purge_missing_command_explains_wrong_view
    @app.handle_key("ctrl_x")
    @app.render

    assert_nil @app.pending_missing_purge
    assert_includes @app.instance_variable_get(:@io_out).string,
                    "Select Missing view to purge tracks"
  end

  def test_purge_missing_captures_only_filtered_visible_ids
    missing = mark_two_tracks_missing
    select_tracks_for(:missing)
    @app.tracks_pane.filter = missing.first.title

    @app.handle_key("ctrl_x")

    assert_equal [missing.first.id], @app.pending_missing_purge[:ids]
  end

  def test_cancel_missing_purge_keeps_tracks
    missing = mark_two_tracks_missing
    select_tracks_for(:missing)
    @app.handle_key("ctrl_x")

    @app.handle_key("escape")

    assert_nil @app.pending_missing_purge
    refute_nil @app.instance_variable_get(:@library).find_track(missing.first.id)
  end

  def test_confirm_missing_purge_deletes_captured_tracks_and_queue_entries
    missing = mark_two_tracks_missing
    @app.engine.enqueue_end(missing)
    select_tracks_for(:missing)
    @app.tracks_pane.filter = missing.first.title
    @app.handle_key("ctrl_x")

    @app.handle_key("y")

    library = @app.instance_variable_get(:@library)
    assert_nil library.find_track(missing.first.id)
    refute_nil library.find_track(missing.last.id)
    refute_includes @app.engine.queue_items.map(&:id), missing.first.id
    assert_nil @app.pending_missing_purge
  end

  def test_confirm_removes_the_folder_from_the_library
    select_library_kind(:folder)
    @app.handle_key("x")
    @app.handle_key("y")
    assert_nil @app.pending_delete
    assert_empty @app.library_pane.rows.select { |r| r.kind == :folder }
  end

  def test_cancel_leaves_the_library_untouched
    select_library_kind(:folder)
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
    select_library_kind(:folder)
    @app.handle_key("n") # enqueue_end the whole folder (not playing)
    assert_operator @app.engine.queue_items.size, :>=, 2

    @app.handle_key("x")
    @app.handle_key("y")

    assert_equal 0, @app.engine.queue_items.size
  end

  def test_confirm_stops_playback_when_the_playing_track_is_deleted
    select_library_kind(:folder)
    @app.handle_key("enter") # play_now: enqueues the folder and starts playing
    wait_until { @app.engine.state[:track] }

    @app.handle_key("x")
    @app.handle_key("y")

    wait_until { @app.engine.queue_items.empty? }
  end

  def test_show_track_info_key_populates_info_track
    select_library_kind(:folder)
    @app.handle_key("tab")              # focus the Tracks pane
    @app.handle_key("i")
    assert_instance_of RubyPlayer::Track, @app.info_track
  end

  def test_show_track_info_key_is_a_noop_in_the_library_pane
    @app.handle_key("i") # library pane active: "i" isn't bound there
    assert_nil @app.info_track
  end

  def test_show_track_info_without_a_selected_track_explains_why
    select_tracks_for(:queue)

    @app.handle_key("i")
    @app.render

    assert_includes @app.instance_variable_get(:@io_out).string,
                    "Select a track to view info"
  end

  def test_rating_without_a_playing_library_track_explains_why
    @app.handle_key("1")
    @app.render

    assert_includes @app.instance_variable_get(:@io_out).string,
                    "Play a library track before rating"
  end

  def test_disabled_queue_sort_explains_why
    select_tracks_for(:queue)

    @app.handle_key("Y")
    @app.render

    assert_includes @app.instance_variable_get(:@io_out).string,
                    "Queue order cannot be sorted or grouped"
  end

  def test_escape_dismisses_the_track_info_modal
    select_library_kind(:folder)
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

  # The status line's default "N tracks in M folders" used to run two
  # COUNT(*) queries on every 30fps frame. These tests pin the fix: at most
  # one query per library change, and the displayed counts still update
  # after the library actually changes.
  def test_folder_stats_query_runs_once_across_frames
    library = @app.instance_variable_get(:@library)
    calls = 0
    library.define_singleton_method(:folder_stats) { calls += 1; super() }
    @app.render
    @app.render
    assert_equal 1, calls
    @app.refresh_panes
    @app.render
    assert_equal 2, calls
  end

  def test_status_track_count_refreshes_after_library_change
    library = @app.instance_variable_get(:@library)
    before = library.folder_stats
    @app.render
    assert_includes back_buffer_text, "#{before[:tracks]} tracks in"

    mark_two_tracks_missing
    @app.refresh_panes
    @app.render
    after = library.folder_stats
    refute_equal before[:tracks], after[:tracks]
    assert_includes back_buffer_text, "#{after[:tracks]} tracks in"
  end

  # The main loop used to repaint 30x/s even when nothing on screen could
  # have changed — an idle TUI burning CPU building identical frames. These
  # tests pin the dirty-flag contract that replaced it: no flush while
  # idle, a flush after every visual change, and exactly one flush when a
  # status message expires (the line flips back to the default text).
  def test_idle_frames_skip_rendering
    flushes = instrument_flushes
    3.times { @app.render_if_needed }
    assert_equal 1, flushes[:n] # only the initial paint
  end

  def test_keypress_marks_frame_dirty
    flushes = instrument_flushes
    @app.render_if_needed
    @app.handle_key("tab")
    2.times { @app.render_if_needed }
    assert_equal 2, flushes[:n]
  end

  def test_bus_events_mark_frame_dirty
    flushes = instrument_flushes
    @app.render_if_needed
    @app.instance_variable_get(:@bus).publish(:queue_changed, items: [])
    @app.handle_events
    2.times { @app.render_if_needed }
    assert_equal 2, flushes[:n]
  end

  def test_status_message_expiry_renders_exactly_once
    clock = { now: 0.0 }
    status = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { clock[:now] })
    @app.instance_variable_set(:@status_line, status)
    flushes = instrument_flushes
    @app.render_if_needed
    status.set_message("hello")
    2.times { @app.render_if_needed }
    assert_equal 2, flushes[:n] # message appeared

    clock[:now] = 10.0
    2.times { @app.render_if_needed }
    assert_equal 3, flushes[:n] # message expired: repaint default once
  end

  def test_playback_animates_every_frame
    start_normal_playback
    flushes = instrument_flushes
    3.times { @app.render_if_needed }
    assert_equal 3, flushes[:n]
  end

  # Companion to dirty-flag rendering: idle, the loop needs no 30fps
  # heartbeat — only a coarse poll for the SIGWINCH resize flag plus a
  # precise wake-up for status-message expiry. Events and stdin already
  # wake IO.select through their own descriptors.
  def test_select_timeout_uses_frame_interval_while_playing
    start_normal_playback
    assert_in_delta 1.0 / 30, @app.select_timeout, 0.001
  end

  def test_select_timeout_relaxes_to_idle_poll_when_stopped
    assert_in_delta 0.25, @app.select_timeout, 0.001
  end

  def test_select_timeout_shrinks_to_status_message_expiry
    clock = { now: 0.0 }
    status = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { clock[:now] })
    @app.instance_variable_set(:@status_line, status)
    status.set_message("hi")
    clock[:now] = 4.9
    assert_in_delta 0.1, @app.select_timeout, 0.02
  end

  # ---- album art ----

  def art_region = @app.instance_variable_get(:@art_region)

  def use_screen(rows: 24, cols: 110)
    out = StringIO.new
    @app.instance_variable_set(:@io_out, out)
    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: rows, cols: cols))
    out
  end

  def play_with_cover_art
    File.binwrite(File.join(@music, "cover.jpg"), File.binread(File.join(FIXTURES, "warrior.jpg")))
    start_normal_playback
    # Art resolves on a background thread and lands as an :art_ready event.
    wait_until do
      @app.handle_events
      @app.instance_variable_get(:@art_bytes)
    end
  end

  def test_art_mode_cycles_and_persists
    assert_equal :off, @app.art_mode
    @app.handle_key("v")
    assert_equal :inset, @app.art_mode
    assert_includes File.read(File.join(@tmp, "config.rb")), 'config.ui.art_mode = "inset"'

    @app.handle_key("v")
    @app.handle_key("v")
    @app.handle_key("v")
    assert_equal :off, @app.art_mode # inset -> pane -> corner -> off
  end

  def test_persisted_art_mode_is_the_next_launch_default
    # The native audio shim allows one instance per process; retire the
    # setup app before booting a second one.
    @app.shutdown
    path = File.join(@tmp, "art-config.rb")
    File.write(path, 'RubyPlayer.configure { |config| config.ui.art_mode = "pane" }' + "\n")
    @app = make_app(config_path: path)
    assert_equal :pane, @app.art_mode
  end

  def test_inset_mode_reserves_bottom_of_library_pane
    play_with_cover_art
    @app.handle_key("v") # -> inset
    use_screen
    @app.render

    region = art_region
    refute_nil region
    content_h = 24 - 4
    assert_equal 1, region[:x] # inside the library box border
    assert_equal content_h - 1 - region[:h], region[:y] # docked at pane bottom
  end

  def test_pane_mode_reserves_right_hand_column
    play_with_cover_art
    2.times { @app.handle_key("v") } # -> pane
    use_screen
    @app.render

    region = art_region
    refute_nil region
    art_w = 30 # ui.art_pane_width default
    assert_equal 110 - art_w + 1, region[:x]
    assert_equal 1, region[:y]
  end

  def test_corner_mode_overlays_bottom_right
    play_with_cover_art
    3.times { @app.handle_key("v") } # -> corner
    use_screen
    @app.render

    region = art_region
    refute_nil region
    assert_equal 8, region[:h] # ui.art_corner_rows default
  end

  def test_art_escape_is_emitted_after_flush_and_not_repeated_when_idle
    play_with_cover_art
    @app.handle_key("v") # -> inset
    out = use_screen

    @app.render_if_needed
    assert_equal 1, out.string.scan("1337;File=inline=1").size

    @app.render_if_needed # idle frame: no repaint, no re-emit
    assert_equal 1, out.string.scan("1337;File=inline=1").size
  end

  def test_no_reemit_while_modal_covers_art_then_reemit_on_close
    play_with_cover_art
    @app.handle_key("v")
    out = use_screen
    @app.render_if_needed
    assert_equal 1, out.string.scan("1337;File=inline=1").size

    @app.handle_key("?") # help modal paints over the panes
    @app.render_if_needed
    # While the modal is up the image must not be re-drawn on top of it.
    assert_equal 1, out.string.scan("1337;File=inline=1").size

    @app.handle_key("escape") # closing repaints cells under the art
    @app.render_if_needed
    assert_equal 2, out.string.scan("1337;File=inline=1").size
  end

  def test_no_escape_without_iterm
    @app.shutdown # native audio shim allows one instance per process
    @app = make_app(env: {}, config_path: File.join(@tmp, "plain-config.rb"))
    @app.scan_paths([@music], wait: true)
    @app.handle_key("v")
    @app.instance_variable_set(:@art_bytes, "IMG".b)
    @app.render

    out = @app.instance_variable_get(:@io_out)
    refute_includes out.string, "1337;File"
  end

  def test_now_playing_needs_a_current_track
    @app.handle_key("o")
    refute @app.show_now_playing
  end

  def test_now_playing_modal_shows_art_and_metadata
    play_with_cover_art
    @app.handle_key("o")
    assert @app.show_now_playing

    out = use_screen
    @app.render_if_needed
    assert_includes back_buffer_text, "Now Playing"
    assert_includes back_buffer_text, @app.engine.state[:track].title[0, 20]
    refute_nil art_region
    assert_equal 1, out.string.scan("1337;File=inline=1").size

    @app.handle_key("escape")
    refute @app.show_now_playing
  end

  def test_now_playing_modal_captures_keys
    play_with_cover_art
    @app.handle_key("o")
    before = @app.active_pane
    @app.handle_key("tab") # swallowed, not pane switch
    assert_equal before, @app.active_pane
    @app.handle_key("o") # o toggles closed
    refute @app.show_now_playing
  end

  # ---- beat pulse ----

  # Deterministic stand-in for BeatTracker: real levels depend on decode
  # timing, but the pulse contract only cares what App does with a step.
  def pin_beat_step(step)
    fake = Object.new
    fake.define_singleton_method(:sample) { |_levels| }
    fake.define_singleton_method(:step) { step }
    fake.define_singleton_method(:reset) {}
    @app.instance_variable_set(:@beat, fake)
  end

  def current_theme = @app.instance_variable_get(:@theme)
  def base_theme = @app.instance_variable_get(:@base_theme)

  def test_pulse_mode_cycles_and_persists
    assert_equal :off, @app.pulse_mode
    @app.handle_key("b")
    assert_equal :low, @app.pulse_mode
    assert_includes File.read(File.join(@tmp, "config.rb")), 'config.ui.pulse_mode = "low"'
    3.times { @app.handle_key("b") }
    assert_equal :off, @app.pulse_mode # low -> medium -> high -> off
  end

  def test_pulse_swaps_in_a_brightened_theme_while_playing
    @app.set_theme!(:neon_cyberpunk)
    start_normal_playback
    @app.handle_key("b") # -> low
    pin_beat_step(7)
    use_screen
    @app.render

    refute_same base_theme, current_theme
    refute_equal base_theme[:border], current_theme[:border]
  end

  def test_pulse_is_identity_when_not_playing
    @app.set_theme!(:neon_cyberpunk)
    @app.handle_key("b")
    pin_beat_step(7)
    use_screen
    @app.render

    assert_same base_theme, current_theme
  end

  def test_pulse_skips_non_truecolor_default_theme
    start_normal_playback
    @app.handle_key("b")
    pin_beat_step(7)
    use_screen
    @app.render

    assert_same base_theme, current_theme
  end

  def test_art_region_shows_spectrum_while_playing_without_art
    start_normal_playback # @music has no cover image
    @app.handle_key("v") # -> inset
    use_screen
    @app.render

    refute_nil art_region
    refute_includes back_buffer_text, "no artwork"
    assert(back_buffer_text.each_char.any? { |c| (0x2800..0x28FF).cover?(c.ord) },
           "expected braille meter cells in the art region")
  end

  def test_album_art_tints_the_accent_color
    play_with_cover_art # warrior.jpg -> real average color via ffmpeg
    use_screen
    @app.render

    accent = current_theme[:accent]
    assert_match(/\A#[0-9a-f]{6}\z/, accent)
    refute_equal base_theme[:accent], accent
  end

  def test_accent_reverts_when_playback_stops
    play_with_cover_art
    @app.instance_variable_get(:@bus).publish(:playback_state, playing: false, paused: false)
    @app.handle_events
    use_screen
    @app.render

    assert_same base_theme, current_theme
  end

  def test_off_mode_reserves_nothing
    play_with_cover_art
    use_screen
    @app.render
    assert_nil art_region
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

  def test_invalid_hot_reload_keeps_active_config_and_shows_modal
    config_path = File.join(@tmp, "config.rb")
    File.write(config_path, <<~RUBY)
      RubyPlayer.configure { |config| config.ui.theme = "ocean_mist" }
    RUBY
    force_config_reload
    assert_equal :ocean_mist, @app.theme_id

    File.write(config_path, "RubyPlayer.configure do |config|\n")
    File.utime(Time.now + 3, Time.now + 3, config_path)
    force_config_reload

    assert_instance_of RubyPlayer::ConfigError, @app.config_error
    assert_equal :ocean_mist, @app.theme_id
    before = @app.active_pane
    @app.handle_key("tab")
    assert_equal before, @app.active_pane

    @app.render
    output = @app.instance_variable_get(:@io_out).string
    assert_includes output, "Configuration Error"
    assert_includes output, "SyntaxError"
    assert_includes output, "config.rb"
  end

  def test_config_error_modal_dismisses_and_corrected_save_clears_it
    config_path = File.join(@tmp, "config.rb")
    File.write(config_path, "RubyPlayer.configure do |config|\n")
    File.utime(Time.now + 2, Time.now + 2, config_path)
    force_config_reload
    refute_nil @app.config_error

    @app.handle_key("escape")
    assert_nil @app.config_error

    File.write(config_path, <<~RUBY)
      RubyPlayer.configure { |config| config.ui.theme = "amber_navy" }
    RUBY
    File.utime(Time.now + 4, Time.now + 4, config_path)
    force_config_reload

    assert_nil @app.config_error
    assert_equal :amber_navy, @app.theme_id
  end

  def test_config_error_modal_keeps_wrapped_message_content_visible
    message = "#{'x' * 70}VISIBLE_SUFFIX"
    @app.instance_variable_set(
      :@config_error,
      RubyPlayer::ConfigError.new(path: "config.rb", message: message)
    )

    @app.render

    screen = @app.instance_variable_get(:@screen)
    rendered = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n")
    assert_includes rendered, "VISI"
    assert_includes rendered, "BLE_SUFFIX"
  end

  def test_startup_fallback_error_is_available_to_modal
    path = File.join(@tmp, "fallback-config.rb")
    previous = File.join(@tmp, "config-previous.rb")
    File.write(previous, <<~RUBY)
      RubyPlayer.configure { |config| config.ui.theme = "ocean_mist" }
    RUBY
    File.write(path, "RubyPlayer.configure do |config|\n")
    @app.shutdown
    @app = nil
    fallback_app = RubyPlayer::UI::App.new(
      config_path: path, data_path: File.join(@tmp, "fallback.sqlite3"),
      null_audio: true, io_out: StringIO.new, focus_player: FakeFocusPlayer.new
    )

    assert_instance_of RubyPlayer::ConfigError, fallback_app.config_error
    assert_equal :ocean_mist, fallback_app.theme_id
  ensure
    fallback_app&.shutdown
  end

  def test_seek_forward_key_issues_absolute_seek_without_error
    select_library_kind(:folder)
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
    select_library_kind(:folder)
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2

    @app.handle_key("tab")              # move focus to tracks pane
    @app.handle_key("down")             # move the tracks-pane cursor off 0
    assert_equal 1, @app.tracks_pane.selection

    @app.send(:refresh_panes)           # simulate a queue_changed/track_started/track_ended event

    assert_equal 1, @app.tracks_pane.selection
    assert_operator @app.tracks_pane.display_rows.size, :>=, 2
  end


  private

  def force_config_reload
    @app.instance_variable_set(
      :@last_config_check,
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - 2
    )
    @app.send(:reload_config_if_changed)
  end

  def mark_two_tracks_missing
    library = @app.instance_variable_get(:@library)
    tracks = library.recently_added.first(2)
    library.mark_missing(track_ids: tracks.map(&:id), folder_ids: [])
    library.recompute_counts!
    @app.library_pane.rebuild!
    tracks
  end

  def back_buffer_text
    back = @app.instance_variable_get(:@screen).instance_variable_get(:@back)
    back.map { |row| row.map(&:ch).join }.join("\n")
  end

  def instrument_flushes
    count = { n: 0 }
    screen = @app.instance_variable_get(:@screen)
    screen.define_singleton_method(:flush) { count[:n] += 1; super() }
    count
  end
end
