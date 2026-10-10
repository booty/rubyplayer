require 'test_helper'

class LevelTapTest < Minitest::Test
  def sine(freq, rate, frames)
    (0...frames).flat_map do |i|
      v = 0.8 * Math.sin(2 * Math::PI * freq * i / rate.to_f)
      [v, v]
    end.pack('e*')
  end

  def test_silence_is_all_zero
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(([0.0] * 2048).pack('e*'))

    assert(tap.levels.all? { |l| l < 0.01 })
  end

  def test_large_chunks_only_unpack_the_retained_window
    tap = RubyPlayer::LevelTap.new(window: 512)
    data = sine(440, 48_000, 4096)
    unpacked_bytes = 0
    trace = TracePoint.new(:call, :c_call) do |event|
      unpacked_bytes += event.self.bytesize if event.method_id == :unpack && event.self.is_a?(String)
    end
    trace.enable { tap.push(data) }

    assert_equal 512 * RubyPlayer::AudioFormat::BYTES_PER_FRAME, unpacked_bytes
  end

  def test_levels_do_not_recompute_frequency_coefficients
    tap = RubyPlayer::LevelTap.new
    calls = 0
    trace = TracePoint.new(:c_call) { |event| calls += 1 if event.method_id == :cos }
    trace.enable { 2.times { tap.levels } }

    assert_equal 0, calls
  end

  def test_short_chunks_preserve_the_same_rolling_window_as_one_large_chunk
    whole = RubyPlayer::LevelTap.new(window: 512)
    split = RubyPlayer::LevelTap.new(window: 512)
    data = sine(440, 48_000, 900)
    whole.push(data)
    frame_bytes = RubyPlayer::AudioFormat::BYTES_PER_FRAME
    [0, 300, 600].each { |offset| split.push(data.byteslice(offset * frame_bytes, 300 * frame_bytes)) }

    assert_equal whole.levels, split.levels
    split.push('')

    assert_equal whole.levels, split.levels
    split.reset

    assert split.levels.all?(&:zero?)
  end

  def test_low_tone_excites_low_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(80, 48_000, 2048))
    levels = tap.levels

    assert_equal 8, levels.size
    assert(levels.all? { |l| l >= 0.0 && l <= 1.0 })
    assert_equal 0, levels.index(levels.max), '80Hz should peak in the lowest band'
  end

  def test_high_tone_excites_high_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(8_000, 48_000, 2048))
    levels = tap.levels

    assert_operator levels.index(levels.max), :>=, 5
  end
end
