require 'test_helper'
require 'open3'
require 'tmpdir'

class RpAudioEffectsTest < Minitest::Test
  def test_delay_generation_exhaustion_never_revives_old_audio
    Dir.mktmpdir do |dir|
      binary = File.join(dir, 'rp_audio_effects_generation_test')
      root = File.expand_path('..', __dir__)
      _out, err, compiled = Open3.capture3(
        'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', "-I#{root}/ext/rp_audio",
        "#{root}/test/rp_audio_effects_generation_test.c", '-lm', '-o', binary
      )

      assert_predicate compiled, :success?, err

      _out, err, ran = Open3.capture3(binary)

      assert_predicate ran, :success?, err
    end
  end

  def test_native_effects_contract
    Dir.mktmpdir do |dir|
      binary = File.join(dir, 'rp_audio_effects_test')
      root = File.expand_path('..', __dir__)
      _out, err, compiled = Open3.capture3(
        'clang', '-std=c11', '-Wall', '-Wextra', '-Werror', "-I#{root}/ext/rp_audio",
        "#{root}/test/rp_audio_effects_test.c", "#{root}/ext/rp_audio/effects.c", '-lm', '-o', binary
      )

      assert_predicate compiled, :success?, err

      _out, err, ran = Open3.capture3(binary)

      assert_predicate ran, :success?, err
    end
  end
end
