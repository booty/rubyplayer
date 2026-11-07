require 'test_helper'
require 'digest'
require 'fileutils'
require 'open3'

class RpAudioCallbackTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  # Every file the test binary compiles: the test includes rp_audio.c, which
  # includes the rest, miniaudio among them.
  SOURCES = %w[test/rp_audio_callback_test.c ext/rp_audio/rp_audio.c ext/rp_audio/effects.c
               ext/rp_audio/effects.h ext/rp_audio/ring_cursor.h ext/rp_audio/miniaudio.h].freeze
  COMPILE_FLAGS = ['-std=c11', '-O2', "-I#{ROOT}/ext/rp_audio"].freeze
  LINK_FLAGS = ['-framework', 'CoreFoundation', '-framework', 'CoreAudio', '-framework', 'AudioToolbox',
                '-lpthread', '-lm'].freeze
  CACHE_DIR = File.join(ROOT, 'tmp/test_bin')

  def test_native_callback_source_boundaries
    _out, err, ran = Open3.capture3(callback_test_binary)

    assert_predicate ran, :success?, err
  end

  private

  # Compiling miniaudio at -O2 takes ~2 s, nearly all of this test's time.
  # The binary is cached under a hash of its sources, flags and compiler,
  # so it is rebuilt exactly when any input changes.
  def callback_test_binary
    clang_version, = Open3.capture2('clang', '--version')
    digest = Digest::SHA256.new
    SOURCES.each { |source| digest.file(File.join(ROOT, source)) }
    digest << (COMPILE_FLAGS + LINK_FLAGS).join("\0") << clang_version
    binary = File.join(CACHE_DIR, "rp_audio_callback_test-#{digest.hexdigest[0, 16]}")
    return binary if File.executable?(binary)

    build(binary)
    binary
  end

  def build(binary)
    FileUtils.mkdir_p(CACHE_DIR)
    # Build beside the target and rename into place, so a concurrent test
    # process never runs a half-written binary.
    partial = "#{binary}.#{Process.pid}.partial"
    _out, err, compiled = Open3.capture3(
      'clang', *COMPILE_FLAGS, File.join(ROOT, 'test/rp_audio_callback_test.c'),
      File.join(ROOT, 'ext/rp_audio/effects.c'), *LINK_FLAGS, '-o', partial
    )

    assert_predicate compiled, :success?, err
    File.rename(partial, binary)
    stale = Dir[File.join(CACHE_DIR, 'rp_audio_callback_test-*')] - [binary]
    FileUtils.rm_f(stale.reject { |path| path.end_with?('.partial') })
  ensure
    FileUtils.rm_f(partial) if partial && File.exist?(partial)
  end
end
