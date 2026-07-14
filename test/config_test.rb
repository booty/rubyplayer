require "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @path = File.join(@dir, "config.rb")
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def write_config(source, path: @path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, source)
    File.utime(Time.now + 2, Time.now + 2, path)
  end

  def test_defaults_when_no_file
    config = RubyPlayer::ConfigStore.new(path: @path)

    assert_equal "auto", config["audio", "sample_rate"]
    assert_equal 33, config["ui", "library_pane_percent"]
    assert_equal 16, config["eq", "bands"]
    assert_respond_to config["ui", "format_track_grouped"], :call
    assert_nil config["nope", "nothing"]
  end

  def test_archive_defaults
    config = RubyPlayer::ConfigStore.new(path: @path)

    assert_equal File.join(Dir.home, ".cache", "rubyplayer", "archives"),
                 config["library", "archive_cache_dir"]
    assert_equal "bsdtar", config["library", "archive_tool"]
  end

  def test_ruby_file_overrides_defaults_and_supports_ruby
    write_config <<~RUBY
      rate = 48_000
      RubyPlayer.configure do |config|
        config.audio.sample_rate = rate
        config.scanner.thread_count = RUBY_VERSION.start_with?("4") ? 4 : 2
        config.backends[".foo"] = :ffmpeg
        config.keymap.global["ctrl+p"] = :play_pause
      end
    RUBY

    config = RubyPlayer::ConfigStore.new(path: @path)

    assert_equal 48_000, config["audio", "sample_rate"]
    assert_equal RUBY_VERSION.start_with?("4") ? 4 : 2, config["scanner", "thread_count"]
    assert_equal :ffmpeg, config["backends", ".foo"]
    assert_equal :play_pause, config["keymap", "global", "ctrl+p"]
    assert_equal 500, config["audio", "ring_buffer_ms"]
  end

  def test_multiple_configure_blocks_apply_in_order
    write_config <<~RUBY
      RubyPlayer.configure { |config| config.ui.frame_fps = 45 }
      RubyPlayer.configure { |config| config.ui.frame_fps = 60 }
    RUBY

    assert_equal 60, RubyPlayer::ConfigStore.new(path: @path)["ui", "frame_fps"]
  end

  def test_all_setting_sections_are_writable
    write_config <<~RUBY
      RubyPlayer.configure do |config|
        config.ui.library_pane_percent = 40
        config.audio.decode_chunk_frames = 2048
        config.scanner.thread_count = 3
        config.library.history_limit = 50
        config.eq.bands = 8
        config.glyphs.star = "*"
        config.keymap.tracks["z"] = :play_now
        config.backends["xyz"] = :ffmpeg
      end
    RUBY

    config = RubyPlayer::ConfigStore.new(path: @path)

    assert_equal 40, config["ui", "library_pane_percent"]
    assert_equal 2048, config["audio", "decode_chunk_frames"]
    assert_equal 3, config["scanner", "thread_count"]
    assert_equal 50, config["library", "history_limit"]
    assert_equal 8, config["eq", "bands"]
    assert_equal "*", config["glyphs", "star"]
    assert_equal :play_now, config["keymap", "tracks", "z"]
    assert_equal :ffmpeg, config["backends", "xyz"]
  end

  def test_unknown_setting_reports_path_and_suggestion
    write_config 'RubyPlayer.configure { |config| config.ui.frame_fpz = 60 }'

    error = assert_raises(RubyPlayer::ConfigError) do
      RubyPlayer::ConfigStore.new(path: @path)
    end

    assert_includes error.message, "ui.frame_fpz"
    assert_includes error.message, "frame_fps"
    assert_equal @path, error.path
  end

  def test_invalid_value_reports_setting_path
    write_config 'RubyPlayer.configure { |config| config.audio.ring_buffer_ms = 0 }'

    error = assert_raises(RubyPlayer::ConfigError) do
      RubyPlayer::ConfigStore.new(path: @path)
    end

    assert_includes error.message, "audio.ring_buffer_ms"
    assert_includes error.message, "positive Integer"
  end

  def test_invalid_dynamic_map_values_fail_during_config_load
    {
      'config.backends[".foo"] = 12' => 'backends[".foo"]',
      'config.keymap.global["x"] = 12' => 'keymap.global["x"]',
    }.each do |assignment, setting|
      write_config "RubyPlayer.configure { |config| #{assignment} }\n"

      error = assert_raises(RubyPlayer::ConfigError) do
        RubyPlayer::ConfigStore.new(path: @path)
      end

      assert_includes error.message, setting
      assert_includes error.message, "String or Symbol"
    end
  end

  def test_runtime_exception_includes_source_location
    write_config <<~RUBY
      RubyPlayer.configure do |_config|
        raise "broken on purpose"
      end
    RUBY

    error = assert_raises(RubyPlayer::ConfigError) do
      RubyPlayer::ConfigStore.new(path: @path)
    end

    assert_includes error.message, "RuntimeError: broken on purpose"
    assert_match(/#{Regexp.escape(@path)}:\d+/, error.message)
  end

  def test_successful_primary_load_refreshes_previous_source
    source = "RubyPlayer.configure { |config| config.eq.bands = 8 }\n"
    write_config source

    config = RubyPlayer::ConfigStore.new(path: @path)

    assert_equal source, File.read(config.previous_path)
    assert_equal File.join(@dir, "config-previous.rb"), config.previous_path
  end

  def test_invalid_primary_uses_valid_previous_at_startup
    previous = File.join(@dir, "config-previous.rb")
    write_config "RubyPlayer.configure { |config| config.eq.bands = 8 }\n", path: previous
    write_config "RubyPlayer.configure do |config|\n"

    config = RubyPlayer::ConfigStore.new(path: @path)

    assert_equal 8, config["eq", "bands"]
    assert_instance_of RubyPlayer::ConfigError, config.startup_error
    assert_includes config.startup_error.message, "SyntaxError"
  end

  def test_invalid_primary_and_previous_are_fatal
    write_config "RubyPlayer.configure do\n", path: File.join(@dir, "config-previous.rb")
    write_config "RubyPlayer.configure do\n"

    error = assert_raises(RubyPlayer::ConfigError) do
      RubyPlayer::ConfigStore.new(path: @path)
    end

    assert_includes error.message, "config.rb"
    assert_includes error.message, "config-previous.rb"
  end

  def test_failed_reload_keeps_active_data_and_waits_for_another_save
    write_config "RubyPlayer.configure { |config| config.eq.bands = 8 }\n"
    config = RubyPlayer::ConfigStore.new(path: @path)
    write_config "RubyPlayer.configure do |config|\n"

    assert_raises(RubyPlayer::ConfigError) { config.reload_if_changed }
    assert_equal 8, config["eq", "bands"]
    refute config.reload_if_changed

    write_config "RubyPlayer.configure { |config| config.eq.bands = 32 }\n"
    assert config.reload_if_changed
    assert_equal 32, config["eq", "bands"]
  end

  def test_reload_detects_same_size_rewrite
    write_config "RubyPlayer.configure { |config| config.eq.bands = 8 }\n"
    config = RubyPlayer::ConfigStore.new(path: @path)
    refute config.reload_if_changed

    write_config "RubyPlayer.configure { |config| config.eq.bands = 4 }\n"

    assert config.reload_if_changed
    assert_equal 4, config["eq", "bands"]
  end

  def test_persist_theme_appends_one_managed_block_and_preserves_user_source
    original = <<~RUBY
      # keep this comment
      RubyPlayer.configure { |config| config.audio.sample_rate = 48_000 }
    RUBY
    write_config original
    config = RubyPlayer::ConfigStore.new(path: @path)

    assert config.persist_theme(:ocean_mist)
    assert config.persist_theme(:amber_navy)

    source = File.read(@path)
    assert_includes source, "# keep this comment"
    assert_includes source, "sample_rate = 48_000"
    assert_equal 1, source.scan("rubyplayer: managed theme begin").size
    assert_match(/config\.ui\.theme = "amber_navy"/, source)
    assert source.end_with?("# rubyplayer: managed theme end\n")
    assert_equal "amber_navy", config["ui", "theme"]
    assert_equal source, File.read(config.previous_path)
    refute config.reload_if_changed
  end

  def test_persist_theme_creates_config_when_missing
    config = RubyPlayer::ConfigStore.new(path: @path)

    config.persist_theme(:basic_terminal)

    assert File.file?(@path)
    assert_equal "basic_terminal", config["ui", "theme"]
  end
end
