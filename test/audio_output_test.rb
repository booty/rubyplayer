require "test_helper"
require "rubyplayer/audio_output"

class AudioOutputTest < Minitest::Test
  class FakeNative
    attr_reader :max_writers

    def initialize
      @mutex = Mutex.new
      @writers = 0
      @max_writers = 0
    end

    def rp_init(*) = 0
    def rp_sample_rate = 48_000

    def rp_write(_ptr, frames)
      @mutex.synchronize do
        @writers += 1
        @max_writers = [@max_writers, @writers].max
      end
      sleep 0.05
      frames
    ensure
      @mutex.synchronize { @writers -= 1 }
    end
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
