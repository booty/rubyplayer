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
end
