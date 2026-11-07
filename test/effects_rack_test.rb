require 'test_helper'
require 'rubyplayer/effects_rack'

class EffectsRackTest < Minitest::Test
  class AudioRecorder
    attr_reader :calls

    def initialize = @calls = []
    def effect_names = %w[Radio Arcade Tube Cassette Bass Underwater Hall Echo]
    def set_effect(id, intensity_percent, reset:) = @calls << [id, intensity_percent, reset]
    def set_effects_bypass(bypass, reset:) = @calls << [bypass, reset]
  end

  def test_independent_effects_keep_their_intensity_and_bypass
    audio = AudioRecorder.new
    rack = RubyPlayer::EffectsRack.new(audio: audio)

    assert_equal audio.effect_names, rack.effects.map(&:name)
    assert rack.effects.none?(&:enabled)
    refute_predicate rack, :bypassed?

    rack.toggle(2)
    rack.adjust(2, 5)
    rack.toggle(7)
    rack.toggle(2)
    rack.toggle(2)

    assert_equal [true, 55], [rack.effects[2].enabled, rack.effects[2].intensity_percent]
    assert_equal [true, 50], [rack.effects[7].enabled, rack.effects[7].intensity_percent]
    assert_equal [[2, 50, false], [2, 55, false], [7, 50, false], [2, 0, true], [2, 55, false]], audio.calls

    rack.toggle_bypass
    rack.toggle_bypass

    assert_equal [[true, true], [false, true]], audio.calls.last(2)
    assert rack.effects[2].enabled
  end

  def test_adjusting_disabled_effect_does_not_turn_it_on
    audio = AudioRecorder.new
    rack = RubyPlayer::EffectsRack.new(audio: audio)
    rack.adjust(0, -100)

    assert_equal 1, rack.effects[0].intensity_percent
    assert_empty audio.calls
    rack.toggle(0)

    assert_equal [[0, 1, false]], audio.calls
    rack.adjust(0, 200)

    assert_equal 100, rack.effects[0].intensity_percent
  end

  def test_step_and_starting_level_are_configurable
    rack = RubyPlayer::EffectsRack.new(audio: AudioRecorder.new, default_intensity_percent: 40, step_percent: 10)
    rack.increase(0)

    assert_equal 50, rack.effects[0].intensity_percent
    rack.decrease(1)

    assert_equal 30, rack.effects[1].intensity_percent
  end
end
