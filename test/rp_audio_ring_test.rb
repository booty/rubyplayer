require "test_helper"
require "open3"
require "tmpdir"

class RpAudioRingTest < Minitest::Test
  def test_stale_callback_cannot_undo_flush
    Dir.mktmpdir do |dir|
      binary = File.join(dir, "rp_audio_ring_test")
      source = File.expand_path("rp_audio_ring_test.c", __dir__)
      include_dir = File.expand_path("../ext/rp_audio", __dir__)
      _stdout, stderr, compile = Open3.capture3(
        "clang", "-std=c11", "-I#{include_dir}", source, "-o", binary
      )
      assert compile.success?, stderr

      _stdout, stderr, run = Open3.capture3(binary)
      assert run.success?, stderr
    end
  end
end
