require 'test_helper'
require 'open3'
require 'tmpdir'

class RpAudioCallbackTest < Minitest::Test
  def test_native_callback_source_boundaries
    Dir.mktmpdir do |dir|
      binary = File.join(dir, 'rp_audio_callback_test')
      root = File.expand_path('..', __dir__)
      _out, err, compiled = Open3.capture3(
        'clang', '-std=c11', '-O2', "-I#{root}/ext/rp_audio",
        "#{root}/test/rp_audio_callback_test.c", "#{root}/ext/rp_audio/effects.c",
        '-framework', 'CoreFoundation', '-framework', 'CoreAudio', '-framework', 'AudioToolbox',
        '-lpthread', '-lm', '-o', binary
      )

      assert_predicate compiled, :success?, err
      _out, err, ran = Open3.capture3(binary)

      assert_predicate ran, :success?, err
    end
  end
end
