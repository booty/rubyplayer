require "test_helper"
require "stringio"

class BrailleMeterTest < Minitest::Test
  BLANK = 0x2800
  FULL = 0x28FF

  def render(levels, w: 4, h: 2)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: h, cols: w)
    RubyPlayer::UI::BrailleMeter.render(screen, levels, x: 0, y: 0, w: w, h: h, fg: nil)
    screen.instance_variable_get(:@back).map { |row| row.map { |cell| cell.ch.ord } }
  end

  def test_silence_renders_blank_braille
    grid = render([0.0] * 8)
    assert(grid.flatten.all? { |ch| ch == BLANK })
  end

  def test_full_levels_fill_every_cell
    grid = render([1.0] * 8)
    assert(grid.flatten.all? { |ch| ch == FULL })
  end

  def test_half_level_fills_bottom_half_only
    grid = render([0.5] * 8)
    assert(grid[0].all? { |ch| ch == BLANK }, "top row must stay empty at 50%")
    assert(grid[1].all? { |ch| ch == FULL }, "bottom row must be solid at 50%")
  end

  def test_bands_map_left_to_right
    # First band silent, last band loud: leftmost cell empty, rightmost full.
    grid = render([0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0])
    assert_equal BLANK, grid[1][0]
    assert_equal FULL, grid[1][3]
  end

  def test_empty_levels_and_degenerate_regions_are_safe
    assert_nil RubyPlayer::UI::BrailleMeter.render(
      RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 2, cols: 2),
      [], x: 0, y: 0, w: 2, h: 2, fg: nil
    )
  end
end
