require 'test_helper'
require_relative '../script/visual/measure'

class VisualMeasureTest < Minitest::Test
  BACKGROUND = [10, 40, 60].freeze

  def test_finds_art_square_and_border_gaps_ignoring_thin_cover_colored_lines
    canvas = Array.new(60) { Array.new(80) { BACKGROUND } }
    # Cyan, like the default theme's active pane border.
    paint(canvas, left: 5, top: 0, width: 1, height: 60, color: [0, 255, 255])
    paint(canvas, left: 70, top: 0, width: 1, height: 60, color: [200, 200, 200])
    paint(canvas, left: 0, top: 50, width: 80, height: 1, color: [200, 200, 200])
    paint(canvas, left: 12, top: 10, width: 40, height: 30, color: [255, 0, 255])
    paint(canvas, left: 22, top: 15, width: 20, height: 20, color: [0, 255, 255])

    result = Visual::Measure.new(canvas.flatten.pack('C*'), 80, 60).result

    assert_equal({ x: 12, y: 10, w: 40, h: 30 }, result[:art])
    assert_in_delta 1.0, result[:square_aspect]
    assert_equal({ left: 6, right: 18, top: nil, bottom: 10 }, result[:gaps])
  end

  def test_reports_missing_art
    canvas = Array.new(20) { Array.new(20) { BACKGROUND } }

    refute Visual::Measure.new(canvas.flatten.pack('C*'), 20, 20).result[:found]
  end

  private

  def paint(canvas, left:, top:, width:, height:, color:)
    (top...(top + height)).each { |row| (left...(left + width)).each { |col| canvas[row][col] = color } }
  end
end
