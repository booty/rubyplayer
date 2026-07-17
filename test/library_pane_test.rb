require "test_helper"
require "tmpdir"
require "stringio"

class LibraryPaneTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @root = @lib.upsert_folder(parent_id: nil, name: "Music", path: "/m", kind: "dir")
    @sega = @lib.upsert_folder(parent_id: @root, name: "Sega", path: "/m/sega", kind: "dir")
    @empty = @lib.upsert_folder(parent_id: nil, name: "Empty", path: "/e", kind: "dir")
    @lib.upsert_track(folder_id: @sega, physical_path: "/m/sega/a.vgm",
                      backend: "gme", format: "vgm", title: "A")
    @lib.recompute_counts!
    @pane = RubyPlayer::UI::LibraryPane.new(library: @lib,
                                            glyphs: RubyPlayer::DEFAULTS["glyphs"])
    @pane.rebuild!
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  def kinds = @pane.rows.map(&:kind)

  def test_specials_then_all_songs_and_visible_roots
    assert_equal %i[queue history favorites focus recent unrated missing failed most_played all folder], kinds
    assert_equal :all, @pane.rows[9].kind
    assert_equal "Music", @pane.rows[10].folder["name"] # Empty (0 tracks) hidden
    assert_equal 1, @pane.rows[10].depth
  end

  def test_smart_views_follow_focus_in_declared_order
    assert_equal %i[recent unrated missing failed most_played], @pane.rows[4, 5].map(&:kind)
  end

  def test_focus_is_below_favorite_tracks
    row = @pane.rows[3]

    assert_equal :focus, row.kind
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 10, active: true, theme: RubyPlayer::Theme::DEFAULT)
    assert_includes screen.flush, "Focus"
  end

  def test_expand_and_collapse
    10.times { @pane.handle_action(:nav_down) } # select Music after fixed views and All Songs
    assert_equal :folder, @pane.selected.kind
    @pane.handle_action(:expand)
    assert_equal %w[Music Sega], @pane.rows.select { |r| r.kind == :folder }.map { |r| r.folder["name"] }
    assert_equal 2, @pane.rows.last.depth
    @pane.handle_action(:collapse)
    assert_equal 11, @pane.rows.size
  end

  def test_all_songs_starts_expanded_and_can_collapse_and_reexpand
    9.times { @pane.handle_action(:nav_down) }

    assert_equal :all, @pane.selected.kind
    assert_equal ["Music"], @pane.rows.select { |row| row.kind == :folder }.map { |row| row.folder["name"] }

    @pane.handle_action(:collapse)
    assert_empty @pane.rows.select { |row| row.kind == :folder }

    @pane.handle_action(:expand)
    assert_equal ["Music"], @pane.rows.select { |row| row.kind == :folder }.map { |row| row.folder["name"] }
  end

  def test_all_songs_collapse_preserves_nested_folder_expansion
    10.times { @pane.handle_action(:nav_down) }
    @pane.handle_action(:expand)
    @pane.handle_action(:nav_up)

    @pane.handle_action(:collapse)
    @pane.handle_action(:expand)

    folders = @pane.rows.select { |row| row.kind == :folder }
    assert_equal %w[Music Sega], folders.map { |row| row.folder["name"] }
    assert_equal [1, 2], folders.map(&:depth)
  end

  def test_all_songs_breadcrumb_and_rendered_label
    row = @pane.rows.find { |candidate| candidate.kind == :all }

    assert_equal "All Songs", @pane.breadcrumb_for(row)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 11, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 11, active: true,
                 theme: RubyPlayer::Theme::DEFAULT)
    assert_includes screen.flush, "All Songs"
  end

  def test_breadcrumb_uses_folder_ancestry
    10.times { @pane.handle_action(:nav_down) }
    @pane.handle_action(:expand)
    @pane.handle_action(:nav_down)

    assert_equal "Music / Sega", @pane.breadcrumb_for(@pane.selected)
    assert_equal "Playback Queue", @pane.breadcrumb_for(@pane.rows.first)
  end

  def test_nav_clamps
    @pane.handle_action(:nav_up)
    assert_equal 0, @pane.selection
    10.times { @pane.handle_action(:nav_down) }
    assert_equal @pane.rows.size - 1, @pane.selection
  end

  def test_page_navigation_jumps_by_last_rendered_height
    # enough roots to page through fixed views + Music + 10 roots
    10.times do |i|
      f = @lib.upsert_folder(parent_id: nil, name: "F#{i}", path: "/f#{i}", kind: "dir")
      @lib.upsert_track(folder_id: f, physical_path: "/f#{i}/t.vgm",
                        backend: "gme", format: "vgm", title: "T")
    end
    @lib.recompute_counts!
    @pane.rebuild!
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 5, cols: 20)
    @pane.render(screen, x: 0, y: 0, w: 20, h: 5, active: true, theme: RubyPlayer::Theme::DEFAULT)

    @pane.handle_action(:nav_page_down)
    assert_equal 5, @pane.selection
    @pane.handle_action(:nav_page_down)
    assert_equal 10, @pane.selection
    @pane.handle_action(:nav_page_up)
    assert_equal 5, @pane.selection
    # clamps at both ends
    5.times { @pane.handle_action(:nav_page_down) }
    assert_equal @pane.rows.size - 1, @pane.selection
    5.times { @pane.handle_action(:nav_page_up) }
    assert_equal 0, @pane.selection
  end

  def test_select_queue_jumps_home
    3.times { @pane.handle_action(:nav_down) }
    @pane.handle_action(:select_queue)
    assert_equal :queue, @pane.selected.kind
  end

  def test_render_shows_specials_folder_and_count
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 11, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 11, active: true, theme: RubyPlayer::Theme::DEFAULT)
    out = screen.flush
    assert_includes out, "Playback Queue"
    assert_includes out, "Music"
    assert_includes out, "(1)"
  end

  def test_render_draws_scrollbar_only_when_rows_overflow
    short = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 11, cols: 20)
    @pane.render(short, x: 0, y: 0, w: 20, h: 11, active: true,
                 theme: RubyPlayer::Theme::DEFAULT)
    refute_includes short.instance_variable_get(:@back).map { |row| row[19].ch }, "█"

    overflowing = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 2, cols: 20)
    @pane.render(overflowing, x: 0, y: 0, w: 20, h: 2, active: true,
                 theme: RubyPlayer::Theme::DEFAULT)
    edge = overflowing.instance_variable_get(:@back).map { |row| row[19].ch }
    assert_includes edge, "█"
    assert_includes edge, "│"
  end
end
