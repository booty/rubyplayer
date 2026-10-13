# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/envelope'
require 'rubyplayer/vgm/patch'

class VgmEnvelopeTest < Minitest::Test
  Envelope = RubyPlayer::Vgm::Envelope
  CLOCK = 7_670_453
  MAX = Envelope::MAX_ATTENUATION_STEPS

  def test_fast_attack_reaches_full_level_then_decays_to_sustain
    params = { ar: 31, d1r: 10, d1l: 4, d2r: 0, rr: 8, tl: 0, rs: 0 }

    assert_equal 0, level(params, held_seconds: 0.0)
    decayed = level(params, held_seconds: 5.0)

    assert_equal 4 * 32, decayed
  end

  def test_slow_attack_rises_over_time
    params = { ar: 8, d1r: 0, d1l: 0, d2r: 0, rr: 8, tl: 0, rs: 0 }

    early = level(params, held_seconds: 0.01)
    later = level(params, held_seconds: 0.2)

    assert_operator early, :>, later
    assert_operator early, :<, MAX
  end

  def test_release_fades_out_and_total_level_attenuates
    params = { ar: 31, d1r: 0, d1l: 0, d2r: 0, rr: 15, tl: 0, rs: 0 }

    assert_equal MAX, level(params, held_seconds: 1.0, release_elapsed_seconds: 0.5)
    assert_equal 40 * 8, level(params.merge(tl: 40), held_seconds: 1.0)
  end

  def test_zero_attack_rate_never_sounds
    assert_equal MAX, level({ ar: 0, d1r: 0, d1l: 0, d2r: 0, rr: 0, tl: 0 }, held_seconds: 1.0)
  end

  def test_channel_level_is_the_loudest_carrier_of_its_algorithm
    loud = operator_parameters(total_level: 0)
    quiet = operator_parameters(total_level: 100)
    patch = RubyPlayer::Vgm::Patch.from_bytes(
      chip: :ym2612, bytes: [4], algorithm: 4, feedback: 0,
      operators: [1, 2, 3, 4].map do |index|
        RubyPlayer::Vgm::Operator.new(index: index, parameters: index == 2 ? loud : quiet)
      end
    )

    assert_equal 0, Envelope.opn_channel(patch, keycode: 0, clock_hz: CLOCK, timings: Array.new(4, [1.0, nil]))
  end

  # Algorithm 0's only carrier is OP4; keying OP1 alone is silent.
  def test_unkeyed_carriers_are_silent
    loud = operator_parameters(total_level: 0)
    patch = RubyPlayer::Vgm::Patch.from_bytes(
      chip: :ym2612, bytes: [0], algorithm: 0, feedback: 0,
      operators: [1, 2, 3, 4].map { |index| RubyPlayer::Vgm::Operator.new(index: index, parameters: loud) }
    )
    timings = [[1.0, nil], [nil, nil], [nil, nil], [nil, nil]]

    assert_equal MAX, Envelope.opn_channel(patch, keycode: 0, clock_hz: CLOCK, timings: timings)
  end

  # RR 0 is the slowest release, not no release.
  def test_zero_release_rate_still_fades
    parameters = operator_parameters(total_level: 0).merge(rr: 0)
    fade = ->(release_elapsed_seconds) { level(parameters, held_seconds: 1.0, release_elapsed_seconds:) }

    assert_operator fade.call(10.0), :>, fade.call(0.0)
    assert_operator fade.call(100.0), :>, fade.call(10.0)
  end

  def test_rates_double_every_four_steps
    envelope_tick_hz = 1_000.0
    code_20_steps_per_second = Envelope.steps_per_second(20, envelope_tick_hz)

    assert_in_delta 2 * code_20_steps_per_second, Envelope.steps_per_second(24, envelope_tick_hz), 1e-9
    assert_in_delta(0.0, Envelope.steps_per_second(1, envelope_tick_hz))
    assert_equal 8 * envelope_tick_hz, Envelope.steps_per_second(63, envelope_tick_hz)
  end

  def test_psg_and_opll_levels
    assert_equal 0, Envelope.psg(0)
    assert_equal MAX, Envelope.psg(15)
    assert_in_delta(-4.0, Envelope.to_db(Envelope.psg(2)), 0.1)
    assert_equal 3 * 32, Envelope.opll_rom(volume: 3)
    assert_equal MAX, Envelope.opll_rom(volume: 0, release_elapsed_seconds: 1.0)
  end

  def test_opll_percussive_patch_decays_while_held
    params = { ar: 15, dr: 6, sl: 2, rr: 7, eg: 0, ksr: 0 }
    sustained = params.merge(eg: 1)

    assert_operator Envelope.opll_custom(params, block: 4, clock_hz: 3_579_545, volume: 0, held_seconds: 2.0), :>,
                    Envelope.opll_custom(sustained, block: 4, clock_hz: 3_579_545, volume: 0, held_seconds: 2.0)
  end

  def test_keycode_uses_block_and_top_fnum_bits
    assert_equal (4 << 2) | 3, Envelope.opn_keycode(fnum: 0x7ff, block: 4)
    assert_equal 4 << 2, Envelope.opn_keycode(fnum: 0x100, block: 4)
  end

  private

  def operator_parameters(total_level:) = { ar: 31, d1r: 0, d1l: 0, d2r: 0, rr: 8, tl: total_level, rs: 0 }

  def level(params, held_seconds:, release_elapsed_seconds: nil)
    Envelope.opn_operator(params, keycode: 0, clock_hz: CLOCK, held_seconds:, release_elapsed_seconds:)
  end
end
