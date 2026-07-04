require "test_helper"
require "stringio"

class ScreenTest < Minitest::Test
  def make_screen(rows: 5, cols: 20)
    RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
  end

  def test_flush_paints_and_positions
    s = make_screen
    s.flush # baseline: the first flush paints the whole blank screen
    s.clear_back
    s.put(1, 2, "hello")
    out = s.flush
    assert_includes out, "hello"
    assert_includes out, "\e[2;3H" # row 1, col 2 -> ANSI is 1-based
  end

  def test_unchanged_frame_emits_nothing
    s = make_screen
    s.put(0, 0, "x")
    s.flush
    s.clear_back
    s.put(0, 0, "x")
    assert_equal "", s.flush
  end

  def test_diff_emits_only_changed_cells
    s = make_screen
    s.put(0, 0, "aaaaaaaaaa")
    s.flush
    s.clear_back
    s.put(0, 0, "aaaaaaaaab") # one changed cell
    out = s.flush
    assert_includes out, "\e[1;10H"
    refute_includes out.delete_prefix("\e[1;10H"), "a" * 3, "should not repaint unchanged run"
  end

  def test_truecolor_and_named_colors
    s = make_screen
    s.put(0, 0, "R", fg: "#ff0000")
    s.put(0, 1, "G", fg: :bright_green, bold: true)
    out = s.flush
    assert_includes out, "38;2;255;0;0"
    assert_includes out, "\e[0;1;92m" # bold + bright_green as one SGR
  end

  def test_clipping_out_of_bounds
    s = make_screen(rows: 2, cols: 5)
    s.put(0, 3, "abcdef") # clips at col 5
    s.put(9, 0, "nope")   # row out of range: ignored
    out = s.flush
    assert_includes out, "ab"
    refute_includes out, "c"
    refute_includes out, "nope"
  end

  def test_resize_forces_full_repaint
    s = make_screen
    s.put(0, 0, "hi")
    s.flush
    s.resize(5, 20)
    s.put(0, 0, "hi")
    assert_includes s.flush, "hi"
  end
end
