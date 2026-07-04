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
