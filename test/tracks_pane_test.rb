require "test_helper"
require "tmpdir"
require "stringio"

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
    @config = RubyPlayer::ConfigStore.new(path: "/nonexistent.rb", create_if_missing: false)
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

  def add(file, title:, album:, artist:, number:, album_artist: nil, year: nil)
    @lib.upsert_track(folder_id: @folder, physical_path: "/m/#{file}",
                      backend: "gme", format: "vgm", title: title, album: album,
                      artist: artist, track_number: number, duration_ms: 60_000,
                      album_artist: album_artist, year: year)
  end

  def titles = @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].title }

  def test_folder_view_lists_tracks
    @pane.show(@folder_row)
    assert_equal 3, titles.size
  end

  def test_title_contains_breadcrumb_and_visible_count
    @pane.show(@folder_row, breadcrumb: "Music / Sega")

    assert_equal "Tracks · Music / Sega · 3", @pane.title
    @pane.filter = "bravo"
    assert_equal "Tracks · Music / Sega · 1", @pane.title
  end

  def test_special_view_title_contains_name_and_count
    @queue = @lib.tracks_under(@folder)
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))

    assert_equal "Playback Queue · 3", @pane.title
  end

  def test_smart_view_loads_library_query_and_uses_dynamic_title
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :unrated, depth: 0))

    assert_equal 3, @pane.display_rows.count { |row| row[:type] == :track }
    assert_equal "Unrated · 3", @pane.title
  end

  def test_all_songs_view_loads_present_tracks_and_uses_dynamic_title
    bravo = @lib.tracks_under(@folder).find { |track| track.title == "Bravo" }
    @lib.mark_missing(track_ids: [bravo.id], folder_ids: [])

    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :all, depth: 0))

    assert_equal %w[Alpha Charlie], titles.sort
    assert_equal "All Songs · 2", @pane.title
  end

  def test_title_left_truncates_to_preserve_leaf_and_count
    @pane.show(@folder_row, breadcrumb: "A Very Long Root / Sega")

    assert_equal "…oot / Sega · 3", @pane.title(max_width: 15)
  end

  def test_filter_matches_track_metadata_case_insensitively
    @pane.show(@folder_row)

    @pane.filter = "y"

    assert_equal %w[Bravo], titles
    @pane.filter = "APPLE"
    assert_equal %w[Alpha Bravo], titles.sort
    @pane.filter = "c.vgm"
    assert_equal %w[Charlie], titles
  end

  def test_filter_matches_focus_titles
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :focus, depth: 0))

    @pane.filter = "dark"

    assert_equal ["Beach Rain (Dark)"], @pane.display_rows.map { |row| row[:text] }
  end

  def test_filter_without_matches_renders_edit_guidance
    @pane.show(@folder_row)

    @pane.filter = "no-such-track"

    assert_equal [{ type: :empty, text: "No matches — press / to edit filter" }],
                 @pane.display_rows
  end

  def test_visible_tracks_returns_only_filtered_missing_view_tracks
    bravo = @lib.tracks_under(@folder).find { |track| track.title == "Bravo" }
    charlie = @lib.tracks_under(@folder).find { |track| track.title == "Charlie" }
    @lib.mark_missing(track_ids: [bravo.id, charlie.id], folder_ids: [])
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :missing, depth: 0))
    @pane.filter = "bravo"

    visible = @pane.visible_tracks

    assert_equal [bravo.id], visible.map(&:id)
    refute_same visible, @pane.visible_tracks
  end

  def test_filter_and_selection_restore_per_view
    queue_row = RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0)
    @queue = @lib.tracks_under(@folder)
    @pane.show(@folder_row)
    @pane.filter = "a"
    @pane.handle_action(:nav_down)
    selected_id = @pane.selected_track.id

    @pane.show(queue_row)
    @pane.filter = "bravo"
    @pane.show(@folder_row)

    assert_equal "a", @pane.filter
    assert_equal selected_id, @pane.selected_track.id

    @pane.show(queue_row)
    assert_equal "bravo", @pane.filter
  end

  def test_selected_queue_track_returns_underlying_track_when_filtered
    @queue = @lib.tracks_under(@folder)
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))

    @pane.filter = "bravo"

    assert_same @queue.find { |track| track.title == "Bravo" }, @pane.selected_queue_track
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

  def test_sort_year_orders_by_year_then_album_then_number
    # Existing setup tracks have nil year (sort as 0, first).
    add("y2.vgm", title: "New", album: "Apple", artist: "X", number: 1, year: 2001)
    add("y1.vgm", title: "Mid", album: "Apple", artist: "X", number: 1, year: 1991)
    @pane.show(@folder_row)
    @pane.handle_action(:sort_year)
    assert_equal %w[Bravo Alpha Charlie Mid New], titles
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

  def test_grouped_album_header_is_rendered_as_a_dashed_separator
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 10, active: true, theme: RubyPlayer::Theme::DEFAULT)
    out = screen.flush
    assert_includes out, "--- Apple #{'-' * (40 - '--- Apple '.size)}"
    assert_includes out, "--- Zebra #{'-' * (40 - '--- Zebra '.size)}"
  end

  def test_render_draws_proportional_scrollbar_when_rows_overflow
    @pane.show(@folder_row)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 2, cols: 20)

    @pane.render(screen, x: 0, y: 0, w: 20, h: 2, active: true,
                 theme: RubyPlayer::Theme::DEFAULT)

    edge = screen.instance_variable_get(:@back).map { |row| row[19].ch }
    assert_includes edge, "█"
    assert_includes edge, "│"
  end

  def test_track_row_styles_title_bold_artist_italic_duration_muted
    @pane.show(@folder_row)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 60)
    theme = RubyPlayer::Theme::DEFAULT
    @pane.render(screen, x: 0, y: 0, w: 60, h: 10, active: true, theme: theme)
    back = screen.instance_variable_get(:@back)

    # Row 1 (not the default selection at row 0) so field colors reflect
    # each field's own style rather than being overridden by selection.
    row = @pane.display_rows[1]
    cell_for = lambda do |text|
      offset = 0
      row[:segments].each do |seg|
        return back[1][offset] if seg[:text] == text
        offset += seg[:text].size
      end
    end

    title_cell = cell_for.call(row[:track].title)
    artist_cell = cell_for.call(row[:track].artist)
    duration_cell = cell_for.call("1:00")

    assert title_cell.bold
    refute title_cell.italic
    assert artist_cell.italic
    refute artist_cell.bold
    assert_equal theme[:text_muted], duration_cell.fg
  end

  def test_selection_colors_override_formatter_colors_but_keep_attributes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.rb")
      File.write(path, <<~RUBY)
        RubyPlayer.configure do |config|
          config.ui.format_track_ungrouped = lambda do |track, fmt|
            fmt.text(track.title, fg: :yellow, bg: :red, italic: true, underline: true)
          end
        end
      RUBY
      pane = RubyPlayer::UI::TracksPane.new(
        library: @lib, config: RubyPlayer::ConfigStore.new(path: path),
        queue_source: -> { @queue }
      )
      pane.show(@folder_row)
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 5, cols: 40)
      theme = RubyPlayer::Theme::DEFAULT

      pane.render(screen, x: 0, y: 0, w: 40, h: 5, active: true, theme: theme)

      cell = screen.instance_variable_get(:@back)[0][0]
      assert_equal theme[:selection_text], cell.fg
      assert_equal theme[:selection_bg], cell.bg
      assert cell.italic
      assert cell.underline
    end
  end

  def test_page_navigation_jumps_by_rendered_height_and_skips_headers
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    # grouped rows: [Apple hdr, Alpha, Bravo, Zebra hdr, Charlie]; selection starts at 1
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 2, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 2, active: true, theme: RubyPlayer::Theme::DEFAULT)

    @pane.handle_action(:nav_page_down) # 1 + 2 = 3 = Zebra header -> nudged to 4
    assert_equal 4, @pane.selection
    assert_equal "Charlie", @pane.selected_track.title
    @pane.handle_action(:nav_page_up) # 4 - 2 = 2 = Bravo
    assert_equal "Bravo", @pane.selected_track.title
    # clamps: page up past the top must land on the first track, not header 0
    @pane.handle_action(:nav_page_up)
    assert_equal "Alpha", @pane.selected_track.title
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

  def test_empty_queue_renders_enqueue_guidance
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))

    assert_equal [{ type: :empty, text: "Queue empty — press N to add selected tracks" }],
                 @pane.display_rows
  end

  def test_empty_history_and_favorites_render_contextual_guidance
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :history, depth: 0))
    assert_equal "No playback history yet", @pane.display_rows.first[:text]

    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :favorites, depth: 0))
    assert_equal "No favorites yet — press 1–6 while a track plays",
                 @pane.display_rows.first[:text]
  end

  def test_empty_folder_renders_generic_view_guidance
    empty_folder = @lib.upsert_folder(parent_id: nil, name: "empty", path: "/empty", kind: "dir")
    row = RubyPlayer::UI::LibraryPane::Row.new(
      kind: :folder, folder: { "id" => empty_folder }, depth: 0
    )

    @pane.show(row)

    assert_equal "No tracks in this view", @pane.display_rows.first[:text]
  end

  def test_empty_guidance_renders_muted_without_becoming_a_track
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)

    @pane.render(screen, x: 0, y: 0, w: 60, h: 3, active: true,
                 theme: RubyPlayer::Theme::DEFAULT)

    assert_includes screen.flush, "Queue empty"
    assert_nil @pane.selected_track
  end

  def test_queue_and_focus_sort_actions_return_disabled_reason
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))
    assert_equal [:disabled, "Queue order cannot be sorted or grouped"],
                 @pane.handle_action(:sort_title)

    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :focus, depth: 0))
    assert_equal [:disabled, "Focus sounds cannot be sorted or grouped"],
                 @pane.handle_action(:toggle_group)
  end

  def test_focus_view_lists_catalog_in_declared_order
    focus = RubyPlayer::FocusSounds::ALL
    pane = RubyPlayer::UI::TracksPane.new(library: @lib, config: @config,
                                          queue_source: -> { @queue }, focus_source: -> { focus })
    pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :focus, depth: 0))

    assert_equal focus.map(&:title), pane.display_rows.map { |row| row[:text] }
    assert_equal focus.first, pane.selected_focus_sound
    assert_nil pane.selected_track
  end

  def test_focus_view_is_not_grouped_or_sorted
    focus = RubyPlayer::FocusSounds::ALL
    pane = RubyPlayer::UI::TracksPane.new(library: @lib, config: @config,
                                          queue_source: -> { @queue }, focus_source: -> { focus })
    pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :focus, depth: 0))

    pane.handle_action(:toggle_group)
    pane.handle_action(:sort_title)
    pane.handle_action(:nav_down)

    refute pane.display_rows.any? { |row| row[:type] == :header }
    assert_equal focus.map(&:title), pane.display_rows.map { |row| row[:text] }
    assert_equal focus[1], pane.selected_focus_sound
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

  # Regression test for the follow-up fix: show() used to RESET
  # @sort/@group_by_album whenever entering :queue mode, which fixed the
  # index-desync bug above but destroyed the user's folder sort/group as a
  # side effect of merely glancing at the queue. Now show() never mutates
  # those flags -- apply_sort/display_rows just ignore them while @mode is
  # :queue -- so a folder's sort must survive a trip through the queue view.
  def test_folder_sort_survives_a_trip_through_the_queue_view
    @queue = [@lib.tracks_under(@folder).find { |t| t.title == "Charlie" }]

    @pane.show(@folder_row)
    @pane.handle_action(:sort_title)
    assert_equal %w[Alpha Bravo Charlie], titles

    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))
    # Queue view itself must still be flat play order, not title-sorted.
    assert_equal %w[Charlie], titles
    refute(@pane.display_rows.any? { |r| r[:type] == :header })

    @pane.show(@folder_row)
    # The folder's sort preference must have survived the queue detour.
    assert_equal %w[Alpha Bravo Charlie], titles
    assert_equal :title, @pane.instance_variable_get(:@sort)
  end

  def test_config_hot_reload_changes_format
    @pane.show(@folder_row)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.rb")
      File.write(path, <<~RUBY)
        RubyPlayer.configure do |config|
          config.ui.format_track_ungrouped = lambda do |track, fmt|
            fmt.text("<<\#{track.title}>>", fg: :accent)
          end
        end
      RUBY
      @pane.update_config(RubyPlayer::ConfigStore.new(path: path))
      assert_includes @pane.display_rows.first[:text], "<<"
      assert_equal :accent, @pane.display_rows.first[:segments].first[:fg]
    end
  end

  # display_rows is called several times per frame at 30fps (render,
  # selected_track, clamp_selection, ...). These tests pin the memoization:
  # repeated calls must not rebuild rows, and every mutation path must
  # invalidate — a stale cache would silently show outdated rows in the TTY,
  # which the rest of the suite (fresh pane per assertion) cannot catch.
  def test_display_rows_are_memoized_between_mutations
    @pane.show(@folder_row)
    assert_same @pane.display_rows, @pane.display_rows
  end

  def test_filter_change_rebuilds_rows
    @pane.show(@folder_row)
    @pane.display_rows
    @pane.filter = "bravo"
    assert_equal %w[Bravo], titles
    @pane.clear_filter
    assert_equal 3, titles.size
  end

  def test_reload_rebuilds_rows
    @pane.show(@folder_row)
    @pane.display_rows
    add("d.vgm", title: "Delta", album: "Apple", artist: "Y", number: 3)
    @pane.reload!
    assert_includes titles, "Delta"
  end

  def test_group_toggle_and_sort_rebuild_rows
    @pane.show(@folder_row)
    @pane.display_rows
    @pane.handle_action(:toggle_group)
    assert(@pane.display_rows.any? { |row| row[:type] == :header })
    @pane.handle_action(:sort_title)
    assert_equal %w[Alpha Bravo Charlie], titles
  end

  def test_update_config_rebuilds_rows
    @pane.show(@folder_row)
    @pane.display_rows
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.rb")
      File.write(path, <<~RUBY)
        RubyPlayer.configure do |config|
          config.ui.format_track_ungrouped = lambda do |track, fmt|
            fmt.text("!!\#{track.title}", fg: :accent)
          end
        end
      RUBY
      @pane.update_config(RubyPlayer::ConfigStore.new(path: path))
      assert_includes @pane.display_rows.first[:text], "!!"
    end
  end

  # ---- playlists ----

  def playlist_row(id, name: "P")
    RubyPlayer::UI::LibraryPane::Row.new(
      kind: :playlist, playlist: { "id" => id, "name" => name }, depth: 1
    )
  end

  def playlists_row
    RubyPlayer::UI::LibraryPane::Row.new(kind: :playlists, depth: 0)
  end

  def track_id(file)
    @lib.all_tracks.find { |t| t.physical_path == "/m/#{file}" }.id
  end

  def test_playlist_mode_shows_tracks_in_position_order
    id = @lib.create_playlist("P")
    @lib.add_to_playlist(id, track_id("b.vgm"))
    @lib.add_to_playlist(id, track_id("a.vgm"))
    @pane.show(playlist_row(id))
    assert_equal %w[Bravo Alpha], titles
    assert_equal id, @pane.playlist_id
  end

  def test_playlist_mode_refuses_sort_and_group
    # Row index == playlist position is load-bearing (move/remove address it),
    # same regression class as the queue view being reordered by a stale @sort.
    id = @lib.create_playlist("P")
    @lib.add_to_playlist(id, track_id("b.vgm"))
    @lib.add_to_playlist(id, track_id("a.vgm"))
    @pane.show(playlist_row(id))
    outcome = @pane.handle_action(:sort_title)
    assert_equal :disabled, outcome[0]
    assert_equal %w[Bravo Alpha], titles
    outcome = @pane.handle_action(:toggle_group)
    assert_equal :disabled, outcome[0]
  end

  def test_stale_sort_flag_does_not_reorder_playlist
    @pane.instance_variable_set(:@sort, :title)
    id = @lib.create_playlist("P")
    @lib.add_to_playlist(id, track_id("b.vgm"))
    @lib.add_to_playlist(id, track_id("a.vgm"))
    @pane.show(playlist_row(id))
    assert_equal %w[Bravo Alpha], titles
  end

  def test_playlists_mode_lists_playlists_and_selects
    @lib.create_playlist("Alpha")
    beta = @lib.create_playlist("Beta")
    @lib.rename_playlist(beta, "Beta") # unambiguous recency bump
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
    @lib.rename_playlist(beta, "Beta") # unambiguous recency bump
    @pane.show(playlists_row)
    names = -> { @pane.display_rows.map { |r| r[:playlist]["name"] } }
    assert_equal %w[Beta Alpha], names.call
    @pane.handle_action(:sort_title)
    assert_equal %w[Alpha Beta], names.call
    @pane.handle_action(:sort_title)
    assert_equal %w[Beta Alpha], names.call
  end

  def test_playlists_mode_filter_matches_names
    @lib.create_playlist("Battle Themes")
    @lib.create_playlist("Chill")
    @pane.show(playlists_row)
    @pane.filter = "batt"
    assert_equal ["Battle Themes"], @pane.display_rows.map { |r| r[:playlist]["name"] }
  end
end
