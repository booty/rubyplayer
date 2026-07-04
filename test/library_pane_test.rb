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

  def test_specials_then_visible_roots_only
    assert_equal %i[queue history favorites folder], kinds
    assert_equal "Music", @pane.rows[3].folder["name"] # Empty (0 tracks) hidden
  end

  def test_expand_and_collapse
    3.times { @pane.handle_action(:nav_down) } # select Music
    assert_equal :folder, @pane.selected.kind
    @pane.handle_action(:expand)
    assert_equal %w[Music Sega], @pane.rows.select { |r| r.kind == :folder }.map { |r| r.folder["name"] }
    assert_equal 1, @pane.rows.last.depth
    @pane.handle_action(:collapse)
    assert_equal 4, @pane.rows.size
  end

  def test_nav_clamps
    @pane.handle_action(:nav_up)
    assert_equal 0, @pane.selection
    10.times { @pane.handle_action(:nav_down) }
    assert_equal @pane.rows.size - 1, @pane.selection
  end

  def test_select_queue_jumps_home
    3.times { @pane.handle_action(:nav_down) }
    @pane.handle_action(:select_queue)
    assert_equal :queue, @pane.selected.kind
  end

  def test_render_shows_specials_folder_and_count
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 10, active: true, theme: RubyPlayer::Theme::DEFAULT)
    out = screen.flush
    assert_includes out, "Playback Queue"
    assert_includes out, "Music"
    assert_includes out, "(1)"
  end
end
