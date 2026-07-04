require "test_helper"
require "rubyplayer/ui/key_decoder"

class KeyDecoderTest < Minitest::Test
  def decode(s) = RubyPlayer::UI::KeyDecoder.decode(s)

  def test_printable_chars_pass_through_case_sensitive
    assert_equal ["a"], decode("a")
    assert_equal ["N"], decode("N")
    assert_equal %w[a b], decode("ab")
  end

  def test_special_keys
    assert_equal ["up"], decode("\e[A")
    assert_equal ["down"], decode("\e[B")
    assert_equal ["right"], decode("\e[C")
    assert_equal ["left"], decode("\e[D")
    assert_equal ["enter"], decode("\r")
    assert_equal ["tab"], decode("\t")
    assert_equal ["space"], decode(" ")
    assert_equal ["escape"], decode("\e")
    assert_equal ["backspace"], decode("\u007F")
  end

  def test_ctrl_chords
    assert_equal ["ctrl_r"], decode("\u0012")
    assert_equal ["ctrl_c"], decode("\u0003")
  end

  def test_bracketed_paste_markers_stripped
    assert_equal %w[/ t m p], decode("\e[200~/tmp\e[201~")
  end
end
