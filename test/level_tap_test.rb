require "test_helper"

class LevelTapTest < Minitest::Test
  def sine(freq, rate, frames)
    (0...frames).flat_map do |i|
      v = 0.8 * Math.sin(2 * Math::PI * freq * i / rate.to_f)
      [v, v]
    end.pack("e*")
  end

  def test_silence_is_all_zero
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(([0.0] * 2048).pack("e*"))
    assert tap.levels.all? { |l| l < 0.01 }
  end

  def test_low_tone_excites_low_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(80, 48_000, 2048))
    levels = tap.levels
    assert_equal 8, levels.size
    assert levels.all? { |l| l >= 0.0 && l <= 1.0 }
    assert_equal 0, levels.index(levels.max), "80Hz should peak in the lowest band"
  end

  def test_high_tone_excites_high_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(8_000, 48_000, 2048))
    levels = tap.levels
    assert_operator levels.index(levels.max), :>=, 5
  end
end
