# frozen_string_literal: true

require 'test_helper'
require_relative 'support/spc_fixture'
require 'rubyplayer/spc/dsp'

class SpcDspTest < Minitest::Test
  Dsp = RubyPlayer::Spc::Dsp

  def test_echo_and_filter_settings_of_megaton_walk
    global = Dsp.global(SpcFixture.regs('earthbound-megaton-walk'))

    assert_equal 0x6c, global[:dir]
    assert_equal 0xe7, global[:esa]
    assert_equal 48, global[:delay_ms]
    assert_equal 6_144, global[:echo_bytes]
    assert_equal 10, global[:efb]
    assert_equal [88, -65, -37, -16, -2, 7, 12, 12], global[:fir]
    assert_equal [112, 112], global[:mvol]
    assert global[:flg][:echo_write]
  end

  def test_phase_inverted_echo_volume_on_kraken_of_the_sea
    global = Dsp.global(SpcFixture.regs('kraken-of-the-sea'))

    assert_equal [90, -66], global[:evol]
    assert global[:evol_inverted]
    refute global[:mvol_inverted]
  end

  def test_noise_and_pitch_modulation_on_last_battle
    regs = SpcFixture.regs('last-battle')
    voices = Array.new(8) { |index| Dsp.voice(regs, index) }

    assert_equal([0], voices.each_index.select { |index| voices[index][:noise] })
    assert_equal([1, 3, 5], voices.each_index.select { |index| voices[index][:pmod] })
    assert_equal 500, Dsp.global(regs)[:flg][:noise_hz]
  end

  def test_echo_writes_disabled_and_gain_envelopes_on_dk_island_swing
    regs = SpcFixture.regs('dk-island-swing')

    refute Dsp.global(regs)[:flg][:echo_write]
    gain_voices = (0..7).reject { |index| Dsp.voice(regs, index)[:adsr][:enabled] }

    assert_equal [1, 2, 3, 4, 5, 6, 7], gain_voices
  end

  def test_maximum_echo_on_confusing_melody
    global = Dsp.global(SpcFixture.regs('confusing-melody'))

    assert_equal 240, global[:delay_ms]
    assert_equal 30_720, global[:echo_bytes]
  end

  def test_voice_pitch_sample_and_pan
    voice = Dsp.voice(SpcFixture.regs('earthbound-megaton-walk'), 0)

    assert_equal 27, voice[:srcn]
    assert_equal 0x3376, voice[:pitch]
    assert_in_delta 0x3376 * 32_000.0 / 0x1000, voice[:rate_hz], 0.001
    assert_equal :left, voice[:pan]
  end

  # No fixture has a per-voice phase-inverted voice, so build one.
  def test_opposite_voice_volumes_read_as_surround
    regs = SpcFixture.regs('earthbound-megaton-walk').dup
    regs[0x10] = 64
    regs[0x11] = 0x100 - 64

    assert_equal :surround, Dsp.voice(regs, 1)[:pan]
  end

  def test_gain_modes
    assert_equal({ mode: :direct, value: 0x38 }, Dsp.gain(0x38))
    assert_equal({ mode: :exp_decrease, value: 0x18 }, Dsp.gain(0xb8))
    assert_equal({ mode: :bent_increase, value: 0x1f }, Dsp.gain(0xff))
  end
end
