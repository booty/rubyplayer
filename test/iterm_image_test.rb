require "test_helper"

class ItermImageTest < Minitest::Test
  Iterm = RubyPlayer::UI::ItermImage

  def test_detects_iterm_via_term_program
    assert Iterm.supported?({ "TERM_PROGRAM" => "iTerm.app" })
    refute Iterm.supported?({ "TERM_PROGRAM" => "Apple_Terminal" })
    refute Iterm.supported?({})
  end

  def test_detects_iterm_over_ssh_via_lc_terminal
    # ssh doesn't forward TERM_PROGRAM, but iTerm2 sets LC_TERMINAL and
    # sshd commonly AcceptEnv's LC_* — the documented remote detection path.
    assert Iterm.supported?({ "LC_TERMINAL" => "iTerm2" })
  end

  def test_escape_encodes_image_as_inline_osc_1337
    bytes = "\xFF\xD8FAKEJPEG".b
    esc = Iterm.escape(bytes, width: 20, height: 10)

    assert esc.start_with?("\e]1337;File=inline=1")
    assert esc.end_with?("\a")
    assert_includes esc, "size=#{bytes.bytesize}"
    assert_includes esc, "width=20"
    assert_includes esc, "height=10"
    assert_includes esc, "preserveAspectRatio=1"
    assert_includes esc, [bytes].pack("m0")
  end

  def test_place_prefixes_cursor_position
    out = Iterm.place("IMG".b, row: 4, col: 9, width: 6, height: 3)
    # ANSI cursor addressing is 1-based; row/col here are 0-based cells.
    assert out.start_with?("\e[5;10H")
    assert_includes out, "1337;File=inline=1"
  end
end
