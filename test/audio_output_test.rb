require "test_helper"
require "open3"
require "rbconfig"
require "rubyplayer/audio_output"

class AudioOutputTest < Minitest::Test
  class FakeNative
    attr_reader :max_writers, :write_calls

    def initialize
      @mutex = Mutex.new
      @writers = 0
      @max_writers = 0
      @write_calls = 0
    end

    def rp_init(*) = 0
    def rp_sample_rate = 48_000

    def rp_write(_ptr, frames)
      @write_calls += 1
      @mutex.synchronize do
        @writers += 1
        @max_writers = [@max_writers, @writers].max
      end
      sleep 0.05
      frames
    ensure
      @mutex.synchronize { @writers -= 1 }
    end

    def rp_free; end
  end

  def test_serializes_concurrent_writes_to_native_ring_buffer
    native = FakeNative.new
    out = RubyPlayer::AudioOutput.new(sample_rate: 48_000, native: native)
    frames = ([0.0] * 256 * 2).pack("e*")

    writers = 2.times.map { Thread.new { out.write(frames) } }
    writers.each(&:join)

    assert_equal 1, native.max_writers
  end

  def test_rejects_non_frame_aligned_pcm
    native = FakeNative.new
    out = RubyPlayer::AudioOutput.new(sample_rate: 48_000, native: native)

    error = assert_raises(ArgumentError) { out.write("\0".b * 9) }
    assert_equal "PCM data must contain complete stereo float32 frames", error.message
  end

  def test_rejects_writes_after_close_before_entering_native_code
    native = FakeNative.new
    out = RubyPlayer::AudioOutput.new(sample_rate: 48_000, native: native)
    out.close

    error = assert_raises(IOError) { out.write("\0".b * 8) }

    assert_equal "audio output is closed", error.message
    assert_equal 0, native.write_calls
  end

  def test_native_write_after_free_returns_zero_instead_of_crashing
    script = <<~'RUBY'
      require "ffi"
      require "rubyplayer/audio_output"
      native = RubyPlayer::RpAudio
      abort "init failed" unless native.rp_init(44_100, 200, 1).zero?
      pointer = FFI::MemoryPointer.new(:float, 2)
      native.rp_free
      exit(native.rp_write(pointer, 1).zero? ? 0 : 1)
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby, "-I#{File.expand_path('../lib', __dir__)}", "-e", script
    )

    assert status.success?, stderr
  end

  # The C shim is a per-process singleton, so exercise the whole lifecycle
  # in one ordered test method.
  def test_null_backend_end_to_end
    out = RubyPlayer::AudioOutput.new(sample_rate: 44_100, ring_buffer_ms: 200,
                                      null_backend: true)
    assert_equal 44_100, out.sample_rate

    silence = ([0.0] * (4096 * 2)).pack("e*")
    accepted = out.write(silence)
    assert_operator accepted, :>, 0
    assert_equal accepted, out.buffered_frames

    out.start
    sleep 0.3
    assert_operator out.frames_played, :>, 0  # null device consumes in real time

    out.paused = true
    out.flush
    assert_equal 0, out.buffered_frames
    out.stop
    out.close
  end
end
