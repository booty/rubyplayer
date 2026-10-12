# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/pitch'
require 'rubyplayer/vgm/chips/sn76489'

class VgmSn76489Test < Minitest::Test
  def setup
    @chip = RubyPlayer::Vgm::Chips::Sn76489.new(clock_hz: 3_579_545, instance: 0,
                                                feedback: 9, shift_width: 16)
  end

  def test_latch_and_continuation_bytes_build_a_tone_period
    write(0x88)
    write(0x3e)
    write(0x90)
    row = @chip.snapshot(sample: 0).channels.first

    assert_equal 1_000, row.details.fetch(:period)
    assert_in_delta 111.86, row.pitch_hz, 0.1
    assert_equal :enabled, row.state
  end

  def test_attenuation_and_stereo_route_determine_enabled_state
    4.times { |channel| write(0x90 | (channel << 5) | 0x0f) }
    muted = @chip.snapshot(sample: 0)
    4.times { |channel| write(0x90 | (channel << 5)) }
    write(0x14, register: :stereo)
    rows = @chip.snapshot(sample: 1).channels

    assert_equal Array.new(4, :muted), muted.channels.map(&:state)
    assert_equal :enabled, rows[0].state
    assert_equal :l, rows[0].pan
    assert_equal :muted, rows[1].state
    assert_equal :r, rows[2].pan
  end

  def test_noise_type_rate_and_tone_three_coupling_are_separate_from_pitch
    write(0x80 | (2 << 5) | 0x0a)
    write(0x90 | (2 << 5))
    write(0xe0 | 0x07)
    noise = @chip.snapshot(sample: 10).channels.fetch(3)

    assert_nil noise.pitch_hz
    assert_equal :white, noise.details.fetch(:noise_type)
    assert_equal :tone_3, noise.details.fetch(:noise_rate)
    assert_equal 9, @chip.snapshot(sample: 10).details.fetch(:noise_feedback)
    assert_equal 16, @chip.snapshot(sample: 10).details.fetch(:shift_width)
  end

  def test_zero_period_uses_the_variant_defined_fallback_without_infinity
    write(0x80)
    write(0x90)
    row = @chip.snapshot(sample: 0).channels.first

    assert_equal 0, row.details.fetch(:period)
    assert_in_delta 109.24, row.pitch_hz, 0.1
    assert_predicate row.pitch_hz, :finite?
  end

  def test_second_instance_has_independent_latch_registers
    second = RubyPlayer::Vgm::Chips::Sn76489.new(clock_hz: 3_579_545, instance: 1)
    @chip.write(port: 0, register: :data, value: 0x90, sample: 0)
    second.write(port: 0, register: :data, value: 0x9f, sample: 0)

    assert_equal :enabled, @chip.snapshot(sample: 0).channels.first.state
    assert_equal :muted, second.snapshot(sample: 0).channels.first.state
    assert_equal 'sn76489:0:0', @chip.snapshot(sample: 0).channels.first.id
    assert_equal 'sn76489:1:0', second.snapshot(sample: 0).channels.first.id
  end

  def test_history_tracks_audibility_and_period_changes
    @chip.write(port: 0, register: :data, value: 0x80 | 0x0e, sample: 0)
    @chip.write(port: 0, register: :data, value: 0x08, sample: 0)
    @chip.write(port: 0, register: :data, value: 0x90 | 0x02, sample: 100)
    @chip.write(port: 0, register: :data, value: 0x90 | 0x04, sample: 150)
    @chip.write(port: 0, register: :data, value: 0x80 | 0x0e, sample: 200)
    @chip.write(port: 0, register: :data, value: 0x10, sample: 200)
    @chip.write(port: 0, register: :data, value: 0x90 | 0x0f, sample: 300)
    snapshot = @chip.snapshot(sample: 300)
    events = RubyPlayer::Vgm::NoteLog.decode(snapshot.details.fetch(:events))

    assert_equal([[:on, 100], [:note, 200], [:off, 300]], events.map { |event| [event.kind, event.sample] })
    assert_equal 300, snapshot.channels.first.details.fetch(:release_sample)
  end

  private

  def write(value, register: :data)
    @chip.write(port: 0, register: register, value: value, sample: 0)
  end
end
