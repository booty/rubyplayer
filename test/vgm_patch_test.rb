# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/patch'
require 'rubyplayer/vgm/pitch'

class VgmPatchTest < Minitest::Test
  def test_signature_is_stable_and_changes_with_timbre_bytes
    baseline = RubyPlayer::Vgm::Patch.from_bytes(chip: :ym2612, bytes: [4, 2, 24, 0, 31])
    equal = RubyPlayer::Vgm::Patch.from_bytes(chip: :ym2612, bytes: [4, 2, 24, 0, 31])
    changed = RubyPlayer::Vgm::Patch.from_bytes(chip: :ym2612, bytes: [4, 2, 25, 0, 31])

    assert_equal baseline.digest, equal.digest
    refute_equal baseline.digest, changed.digest
    assert_equal 12, baseline.short_digest.length
    assert_equal 64, baseline.digest.length
  end

  def test_pitch_helpers_convert_chip_frequency_and_format_nearest_note
    # From fnum * clock * 2^(block - 1) / (144 * 2^20), using a 7,670,454 Hz
    # clock. Regression: the formula once dropped the -1 and read an octave high.
    frequency = RubyPlayer::Vgm::Pitch.ym2612_hz(clock_hz: 7_670_454, fnum: 608, block: 4)
    note, cents = RubyPlayer::Vgm::Pitch.note_and_cents(frequency)

    assert_in_delta 247.0883, frequency, 0.001
    assert_equal 'B3', note
    assert_in_delta 0, cents, 1
    assert_nil RubyPlayer::Vgm::Pitch.psg_hz(clock_hz: 3_579_545, period: 0, zero_period: nil)
  end
end
