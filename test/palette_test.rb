require "test_helper"

class PaletteTest < Minitest::Test
  def test_set_emits_osc_4_with_xterm_rgb_spec
    assert_equal "\e]4;3;rgb:1a/2b/3c\a", RubyPlayer::UI::Palette.set(3, "#1a2b3c")
  end

  def test_reset_emits_osc_104
    assert_equal "\e]104\a", RubyPlayer::UI::Palette.reset
  end
end
