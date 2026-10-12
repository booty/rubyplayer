require 'test_helper'

class LevelTapTest < Minitest::Test
  FRAME_BYTES = RubyPlayer::AudioFormat::BYTES_PER_FRAME

  def sine(freq, rate, frames)
    (0...frames).flat_map do |i|
      v = 0.8 * Math.sin(2 * Math::PI * freq * i / rate.to_f)
      [v, v]
    end.pack('e*')
  end

  def peak_band(levels) = levels.index(levels.max)

  def test_silence_is_all_zero
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(([0.0] * 2048).pack('e*'), start_frame: 0)

    assert(tap.levels(at_frame: 1024).all? { |l| l < 0.01 })
  end

  # Regression: levels analysed the newest *decoded* audio, which runs up to a
  # ring buffer ahead of the speakers, and with large decode chunks it only
  # changed once per chunk. Levels now follow the frame actually being played.
  def test_levels_follow_the_playback_frame_not_the_newest_push
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(80, 48_000, 2048) + sine(8_000, 48_000, 2048), start_frame: 10_000)

    assert_equal 0, peak_band(tap.levels(at_frame: 12_048))
    assert_operator peak_band(tap.levels(at_frame: 14_096)), :>=, 5
  end

  def test_frames_without_written_audio_read_as_silence
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(440, 48_000, 2048), start_frame: 5_000)

    assert(tap.levels(at_frame: 4_000).all?(&:zero?))
    assert(tap.levels(at_frame: 50_000).all?(&:zero?))
  end

  # A flush discards buffered audio, so the next write reuses timeline
  # positions; that newer audio must replace whatever was pushed there.
  def test_push_at_an_earlier_frame_replaces_stale_audio
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(8_000, 48_000, 4096), start_frame: 0)
    tap.push(sine(80, 48_000, 2048), start_frame: 1_000)

    assert_equal 0, peak_band(tap.levels(at_frame: 3_000))
    assert(tap.levels(at_frame: 4_000).all?(&:zero?))
  end

  def test_window_spanning_several_pushes_matches_one_large_push
    whole = RubyPlayer::LevelTap.new(window: 512)
    split = RubyPlayer::LevelTap.new(window: 512)
    data = sine(440, 48_000, 900)
    whole.push(data, start_frame: 0)
    [0, 300, 600].each do |offset|
      split.push(data.byteslice(offset * FRAME_BYTES, 300 * FRAME_BYTES), start_frame: offset)
    end
    split.push('', start_frame: 900)

    assert_equal whole.levels(at_frame: 800), split.levels(at_frame: 800)
    split.reset

    assert split.levels(at_frame: 800).all?(&:zero?)
  end

  # Decode bursts can be large; only the analysed window is ever unpacked.
  def test_push_never_unpacks_and_levels_unpack_only_the_window
    tap = RubyPlayer::LevelTap.new(window: 512)
    data = sine(440, 48_000, 16_384)
    unpacked_bytes = 0
    # String#unpack is Ruby-defined in Ruby 4, so trace both call kinds.
    trace = TracePoint.new(:call, :c_call) do |event|
      unpacked_bytes += event.self.bytesize if %i[unpack unpack1].include?(event.method_id) && event.self.is_a?(String)
    end
    trace.enable { tap.push(data, start_frame: 0) }

    assert_equal 0, unpacked_bytes

    trace.enable { tap.levels(at_frame: 8_000) }

    assert_equal 512 * FRAME_BYTES, unpacked_bytes
  end

  def test_retention_is_bounded_by_retain_frames
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000, retain_frames: 4_096)
    chunk = sine(80, 48_000, 1_024)
    100.times { |index| tap.push(chunk, start_frame: index * 1_024) }

    assert(tap.levels(at_frame: 2_048).all?(&:zero?))
    assert_operator tap.levels(at_frame: 100 * 1_024).max, :>, 0.1
  end

  def test_levels_do_not_recompute_frequency_coefficients
    tap = RubyPlayer::LevelTap.new
    calls = 0
    trace = TracePoint.new(:c_call) { |event| calls += 1 if event.method_id == :cos }
    trace.enable { 2.times { tap.levels(at_frame: 0) } }

    assert_equal 0, calls
  end

  def test_low_tone_excites_low_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(80, 48_000, 2048), start_frame: 0)
    levels = tap.levels(at_frame: 2048)

    assert_equal 8, levels.size
    assert(levels.all? { |l| l >= 0.0 && l <= 1.0 })
    assert_equal 0, peak_band(levels), '80Hz should peak in the lowest band'
  end

  def test_high_tone_excites_high_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(8_000, 48_000, 2048), start_frame: 0)

    assert_operator peak_band(tap.levels(at_frame: 2048)), :>=, 5
  end
end
