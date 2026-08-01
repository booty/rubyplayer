require "test_helper"

class DurationFormatterTest < Minitest::Test
  def test_formats_known_duration
    assert_equal "2:05", RubyPlayer::DurationFormatter.format(125_000)
    assert_equal "0:00", RubyPlayer::DurationFormatter.format(0)
  end

  def test_uses_caller_selected_unknown_placeholder
    assert_nil RubyPlayer::DurationFormatter.format(nil)
    assert_equal "?:??", RubyPlayer::DurationFormatter.format(false, unknown: "?:??")
    assert_equal "?:??", RubyPlayer::DurationFormatter.format(nil, unknown: "?:??")
    assert_equal "unknown", RubyPlayer::DurationFormatter.format(nil, unknown: "unknown")
  end

  def test_rejects_non_integer_duration
    assert_raises(TypeError) { RubyPlayer::DurationFormatter.format("125000") }
  end
end
