require "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  def test_defaults_when_no_file
    c = RubyPlayer::ConfigStore.new(path: "/nonexistent/config.toml")
    assert_equal "auto", c["audio", "sample_rate"]
    assert_equal 33, c["ui", "library_pane_percent"]
    assert_equal 16, c["eq", "bands"]
    assert_nil c["nope", "nothing"]
  end

  def test_archive_defaults
    c = RubyPlayer::ConfigStore.new(path: "/nonexistent/config.toml")
    assert_equal File.join(Dir.home, ".cache", "rubyplayer", "archives"),
                 c["library", "archive_cache_dir"]
    assert_equal "bsdtar", c["library", "archive_tool"]
  end

  def test_file_overrides_defaults_deeply
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "[audio]\nsample_rate = 48000\n")
      c = RubyPlayer::ConfigStore.new(path: path)
      assert_equal 48000, c["audio", "sample_rate"]
      assert_equal 500, c["audio", "ring_buffer_ms"] # untouched default survives
    end
  end

  def test_invalid_toml_falls_back_to_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "= this is [not toml")
      c = RubyPlayer::ConfigStore.new(path: path)
      assert_equal "auto", c["audio", "sample_rate"]
    end
  end

  def test_persist_theme_creates_file_when_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "nested", "config.toml")
      c = RubyPlayer::ConfigStore.new(path: path)
      c.persist_theme(:neon_cyberpunk)
      assert_equal "neon_cyberpunk", c["ui", "theme"]
      assert_equal "neon_cyberpunk", Tomlrb.load_file(path).dig("ui", "theme")
    end
  end

  def test_persist_theme_preserves_other_content_in_the_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, <<~TOML)
        # a comment the user wrote
        [audio]
        sample_rate = 48000

        [ui]
        frame_fps = 60
      TOML
      c = RubyPlayer::ConfigStore.new(path: path)
      c.persist_theme(:solarized_dark_like)

      raw = File.read(path)
      assert_includes raw, "# a comment the user wrote"
      assert_includes raw, "sample_rate = 48000"
      assert_includes raw, "frame_fps = 60"
      data = Tomlrb.load_file(path)
      assert_equal "solarized_dark_like", data.dig("ui", "theme")
      assert_equal 60, data.dig("ui", "frame_fps")
    end
  end

  def test_persist_theme_overwrites_an_existing_theme_line
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "[ui]\ntheme = \"basic_terminal\"\nframe_fps = 60\n")
      c = RubyPlayer::ConfigStore.new(path: path)
      c.persist_theme(:amber_navy)

      data = Tomlrb.load_file(path)
      assert_equal "amber_navy", data.dig("ui", "theme")
      assert_equal 60, data.dig("ui", "frame_fps")
      assert_equal 1, File.read(path).scan(/^theme\s*=/).size
    end
  end

  def test_persist_theme_does_not_trigger_a_spurious_reload
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      c = RubyPlayer::ConfigStore.new(path: path)
      c.persist_theme(:ocean_mist)
      refute c.reload_if_changed
    end
  end

  def test_reload_if_changed
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "[eq]\nbands = 8\n")
      c = RubyPlayer::ConfigStore.new(path: path)
      assert_equal 8, c["eq", "bands"]
      refute c.reload_if_changed
      File.write(path, "[eq]\nbands = 32\n")
      File.utime(Time.now + 2, Time.now + 2, path) # force mtime change
      assert c.reload_if_changed
      assert_equal 32, c["eq", "bands"]
    end
  end
end
