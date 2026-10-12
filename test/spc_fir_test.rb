# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/spc/fir'

class SpcFirTest < Minitest::Test
  Fir = RubyPlayer::Spc::Fir

  def test_fixture_filters_are_classified
    assert_equal 'high-pass', Fir.kind([88, -65, -37, -16, -2, 7, 12, 12])
    assert_equal 'low-pass', Fir.kind([12, 33, 43, 43, 19, -2, -13, -7])
    assert_equal 'flat', Fir.kind([127, 0, 0, 0, 0, 0, 0, 0])
  end

  def test_response_spans_the_clamped_db_range
    curve = Fir.response([88, -65, -37, -16, -2, 7, 12, 12], points: 24)

    assert_equal 24, curve.size
    assert_in_delta(-24.0, curve.first)
    assert_in_delta 0.0, curve.last, 1.0
    assert(curve.all? { |db| db.between?(-24.0, 12.0) })
  end

  def test_all_zero_taps_are_silent_not_an_error
    assert_equal Array.new(4, -24.0), Fir.response(Array.new(8, 0), points: 4)
  end
end
