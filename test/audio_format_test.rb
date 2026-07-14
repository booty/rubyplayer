require "test_helper"
require "rubyplayer/audio_format"

class AudioFormatTest < Minitest::Test
  def test_stereo_float32_contract
    format = RubyPlayer::AudioFormat

    assert_equal 2, format::CHANNELS
    assert_equal 32, format::BITS_PER_SAMPLE
    assert_equal 8, format::BYTES_PER_FRAME
    assert_equal ["-e", "floating-point", "-b", "32", "-c", "2"], format::SOX_RAW_ARGS
  end
end
