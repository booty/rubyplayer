require "test_helper"
require_relative "support/app_test_support"

class AppTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_scan_populates_library_and_panes
    rows = @app.library_pane.rows
    folder = rows.find { |row| row.kind == :folder }
    assert_operator folder.folder["track_count"], :>=, 2
  end

  def test_selecting_all_songs_displays_every_present_track
    expected_ids = @app.instance_variable_get(:@library).all_tracks.map(&:id)

    select_tracks_for(:all)

    assert_equal expected_ids, @app.tracks_pane.visible_tracks.map(&:id)
    assert_equal "All Songs · #{expected_ids.size}", @app.tracks_pane.title
  end

  def test_tab_cycles_active_pane
    assert_equal :library, @app.active_pane
    @app.handle_key("tab")
    assert_equal :tracks, @app.active_pane
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
    wait_until(timeout: 2, interval: 0.01, failure_message: "timed out waiting for condition") { @app.engine.state[:track] }

    @app.handle_key("x")
    @app.handle_key("y")

    wait_until(timeout: 2, interval: 0.01, failure_message: "timed out waiting for condition") { @app.engine.queue_items.empty? }
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

  def test_selected_tracks_for_sidebar_playlist_child
    lib = @app.instance_variable_get(:@library)
    tid = seed_playlist_tracks(%w[a]).first
    pid = lib.create_playlist("P")
    lib.add_to_playlist(pid, tid)
    @app.library_pane.rebuild!
    assert @app.library_pane.select_playlist(pid)
    @app.instance_variable_set(:@active_pane, :library)
    assert_equal ["A"], @app.selected_tracks.map(&:title)
  end

  def test_enter_on_playlist_list_row_jumps_into_playlist
    lib = @app.instance_variable_get(:@library)
    pid = lib.create_playlist("P")
    pane = @app.library_pane
    pane.rebuild!
    pane.instance_variable_set(:@selection, pane.rows.index { |r| r.kind == :playlists })
    @app.send(:show_selected_tracks)
    @app.instance_variable_set(:@active_pane, :tracks)
    @app.handle_key("enter")
    assert_equal :playlist, pane.selected.kind
    assert_equal pid, pane.selected.playlist["id"]
    assert_equal pid, @app.tracks_pane.playlist_id
  end

  def test_ctrl_down_moves_playlist_entry_and_selection_follows
    lib = @app.instance_variable_get(:@library)
    ids = seed_playlist_tracks(%w[a b])
    pid = lib.create_playlist("P")
    ids.each { |t| lib.add_to_playlist(pid, t) }
    open_playlist(pid)
    @app.handle_key("ctrl_down") # move A below B
    assert_equal %w[B A], lib.playlist_tracks(pid).map(&:title)
    # Selection follows the moved track (reload! restores by identity).
    assert_equal "A", @app.tracks_pane.selected_track.title
  end

  def test_x_removes_playlist_entry
    lib = @app.instance_variable_get(:@library)
    tid = seed_playlist_tracks(%w[a]).first
    pid = lib.create_playlist("P")
    lib.add_to_playlist(pid, tid)
    open_playlist(pid)
    @app.handle_key("x")
    assert_empty lib.playlist_tracks(pid)
  end

  def test_move_refused_while_filter_active
    lib = @app.instance_variable_get(:@library)
    ids = seed_playlist_tracks(%w[a b])
    pid = lib.create_playlist("P")
    ids.each { |t| lib.add_to_playlist(pid, t) }
    open_playlist(pid)
    @app.tracks_pane.filter = "B"
    @app.handle_key("ctrl_down")
    assert_equal %w[A B], lib.playlist_tracks(pid).map(&:title)
  end

  def test_l_opens_add_modal_and_typing_a_name_creates_playlist_with_track
    lib = @app.instance_variable_get(:@library)
    tid = seed_playlist_tracks(%w[a]).first
    show_all_songs_in_tracks_pane
    @app.handle_key("l")
    refute_nil @app.playlist_modal
    selected = @app.tracks_pane.selected_track.id
    "Mix".each_char { |ch| @app.handle_key(ch) }
    @app.handle_key("enter") # only row is "New playlist: Mix"
    assert_nil @app.playlist_modal
    lists = lib.playlists
    assert_equal ["Mix"], lists.map { |p| p["name"] }
    assert_equal [selected], lib.playlist_tracks(lists.first["id"]).map(&:id)
    assert_kind_of Integer, tid
  end

  def test_add_modal_picks_existing_playlist
    lib = @app.instance_variable_get(:@library)
    seed_playlist_tracks(%w[a])
    pid = lib.create_playlist("Mix")
    show_all_songs_in_tracks_pane
    selected = @app.tracks_pane.selected_track.id
    @app.handle_key("l")
    @app.handle_key("enter") # first row: recent "Mix"
    assert_nil @app.playlist_modal
    assert_equal [selected], lib.playlist_tracks(pid).map(&:id)
  end

  def test_add_modal_confirms_duplicates
    lib = @app.instance_variable_get(:@library)
    seed_playlist_tracks(%w[a])
    pid = lib.create_playlist("Mix")
    show_all_songs_in_tracks_pane
    selected = @app.tracks_pane.selected_track.id
    lib.add_to_playlist(pid, selected)
    @app.handle_key("l")
    @app.handle_key("enter")
    refute_nil @app.playlist_modal[:confirm] # already contains the track
    @app.handle_key("n")
    assert_nil @app.playlist_modal[:confirm] # back to the list
    @app.handle_key("enter")
    @app.handle_key("y")
    assert_nil @app.playlist_modal
    assert_equal [selected, selected], lib.playlist_tracks(pid).map(&:id)
  end

  def test_add_modal_escape_cancels
    seed_playlist_tracks(%w[a])
    show_all_songs_in_tracks_pane
    @app.handle_key("l")
    @app.handle_key("escape")
    assert_nil @app.playlist_modal
  end

  def test_l_without_selected_track_shows_message_not_modal
    @app.instance_variable_set(:@active_pane, :library)
    @app.handle_key("l")
    assert_nil @app.playlist_modal
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
    tid = seed_playlist_tracks(%w[a]).first
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
    lib.create_playlist("Kept")
    select_playlist_child(lib.playlists.first["id"])
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
end
