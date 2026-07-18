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

  def test_underline_and_dim_are_emitted_and_part_of_cell_style
    s = make_screen
    s.put(0, 0, "x", underline: true, dim: true)
    output = s.flush

    assert_includes output, "\e[0;2;4m"
    cell = s.instance_variable_get(:@front)[0][0]
    assert cell.underline
    assert cell.dim
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

  # Damage reporting exists for overlays drawn outside the cell model
  # (iTerm2 inline images): the overlay owner must know whether the last
  # flush repainted cells under its rectangle, because any such repaint
  # erases part of the image and forces a re-emit.
  def test_region_damaged_reflects_last_flush
    s = make_screen
    s.flush # initial full paint
    s.clear_back
    s.put(2, 4, "hello")
    s.flush

    assert s.region_damaged?(rows: 2..2, cols: 4..8)
    assert s.region_damaged?(rows: 0..4, cols: 8..8) # overlaps last char
    refute s.region_damaged?(rows: 3..4, cols: 0..19) # other rows untouched
    refute s.region_damaged?(rows: 2..2, cols: 9..19) # same row, past the text
  end

  def test_region_damaged_clears_on_quiet_flush
    s = make_screen
    s.put(1, 1, "x")
    s.flush
    s.clear_back
    s.put(1, 1, "x")
    s.flush # no changes emitted

    refute s.region_damaged?(rows: 0..4, cols: 0..19)
  end

  def test_full_repaint_damages_everything
    s = make_screen
    s.flush
    s.resize(5, 20)
    s.flush

    assert s.region_damaged?(rows: 4..4, cols: 19..19)
  end
end
