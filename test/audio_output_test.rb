require "test_helper"
require "rubyplayer/audio_output"

class AudioOutputTest < Minitest::Test
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
