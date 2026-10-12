# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/pitch'
require 'rubyplayer/vgm/patch'
require 'rubyplayer/vgm/chips/ym2612'

class VgmYm2612Test < Minitest::Test
  def setup
    @chip = RubyPlayer::Vgm::Chips::Ym2612.new(clock_hz: 7_670_454)
  end

  def test_key_masks_cover_six_channels_on_both_ports_and_ignore_invalid_codes
    6.times do |channel|
      code = channel % 3
      write(0x28, 0xf0 | ((channel / 3) << 2) | code, sample: 10 + channel)
    end
    write(0x28, 0xf0 | 3, sample: 30)
    rows = @chip.snapshot(sample: 30).channels

    assert_equal Array.new(6, :key_on), rows.map(&:state)
    assert_equal 0x0f, rows[5].details.fetch(:key_mask)
    assert_equal 15, rows[5].last_trigger_sample
  end

  def test_key_off_preserves_a_short_recent_trigger_edge
    write(0x28, 0xf0, sample: 100)
    write(0x28, 0x00, sample: 101)
    row = @chip.snapshot(sample: 500).channels.first

    assert_equal :key_off, row.state
    assert_equal 100, row.last_trigger_sample
    assert_operator 500 - row.last_trigger_sample, :<, RubyPlayer::Vgm::Chips::Ym2612::RECENT_SAMPLES
  end

  def test_explicit_operator_slot_mapping_decodes_all_parameter_groups
    [0, 1, 2, 3].each do |operator|
      register = 0x30 + RubyPlayer::Vgm::Chips::Ym2612::OPERATOR_OFFSETS.fetch(operator)
      write(register, 0x21 + operator)
      write(register + 0x10, 0x40 + operator)
      write(register + 0x20, 0x80 + operator)
      write(register + 0x30, 0x10 + operator)
      write(register + 0x40, 0x05 + operator)
      write(register + 0x50, 0x68 + operator)
      write(register + 0x60, 0x90 + operator)
    end
    operators = @chip.snapshot(sample: 0).channels.first.patch.operators

    assert_equal([1, 2, 3, 4], operators.map { |op| op.parameters.fetch(:mul) })
    assert_equal([0x40, 0x41, 0x42, 0x43], operators.map { |op| op.parameters.fetch(:tl) })
    assert_equal([0, 0, 0, 0], operators.map { |op| op.parameters.fetch(:am) })
    assert_equal([0, 1, 2, 3], operators.map { |op| op.parameters.fetch(:ssg_eg) })
  end

  def test_frequency_commit_pitch_feedback_pan_and_patch_identity
    write(0xb0, 0x34)
    write(0xb4, 0xc0 | (2 << 4) | 3)
    write(0xa4, 0x20 | 2)
    before_commit = @chip.snapshot(sample: 0).channels.first
    write(0xa0, 608 & 0xff)
    first = @chip.snapshot(sample: 0).channels.first
    digest = first.patch.digest
    write(0x28, 0xf0, sample: 20)
    write(0xb4, 0x40)
    write(0xa4, 0x21)
    same_timbre = @chip.snapshot(sample: 20).channels.first
    write(0x40, 25)
    changed_timbre = @chip.snapshot(sample: 20).channels.first

    assert_nil before_commit.pitch_hz
    assert_in_delta 494.1767, first.pitch_hz, 0.001
    assert_equal 'B4', first.note
    assert_equal 4, first.patch.algorithm
    assert_equal 6, first.patch.feedback
    assert_equal :lr, first.pan
    assert_equal digest, same_timbre.patch.digest
    refute_equal digest, changed_timbre.patch.digest
  end

  def test_channel_three_special_mode_reports_operator_pitches
    write(0x27, 0x40)
    write(0xa8, 0x34)
    write(0xac, 0x12)
    row = @chip.snapshot(sample: 0).channels.fetch(2)

    assert_equal :special, row.note
    assert_nil row.pitch_hz
    assert_equal 0x234, row.details.fetch(:special_frequencies).first.fetch(:fnum)
  end

  def test_dac_enable_keeps_channel_six_fm_state_and_tracks_recent_data
    write(0x28, 0xf0 | 0x04 | 2, sample: 1)
    write(0x2b, 0x80)
    write(0x2a, 0x66, sample: 100)
    data = @chip.snapshot(sample: 200).channels.fetch(5)
    idle = @chip.snapshot(sample: 5_000).channels.fetch(5)
    write(0x2b, 0x00)
    fm = @chip.snapshot(sample: 5_001).channels.fetch(5)

    assert_equal :pcm, data.kind
    assert_equal :data, data.state
    assert_equal 0x66, data.details.fetch(:dac_value)
    assert_equal :idle, idle.state
    assert_equal :fm, fm.kind
    assert_equal :key_on, fm.state
  end

  def test_port_one_does_not_change_port_zero_global_key_dac_or_special_mode
    write(0x28, 0xf0, sample: 1)
    write(0x2b, 0x80)
    write(0x27, 0x40)
    write(0xa8, 0x34)
    write(0xac, 0x12)
    write(0x28, 0x00, sample: 2, port: 1)
    write(0x2b, 0x00, port: 1)
    write(0x27, 0x00, port: 1)
    write(0xa8, 0x00, port: 1)
    write(0xac, 0x00, port: 1)
    before_mode = @chip.snapshot(sample: 2)

    assert_equal :key_on, before_mode.channels.first.state
    assert before_mode.details.fetch(:dac_enabled)
    special = before_mode.channels.fetch(2).details.fetch(:special_frequencies).first

    assert_equal [0x234, 2], special.values_at(:fnum, :block)
    assert_equal :special, before_mode.channels.fetch(2).note
  end

  def test_state_dump_and_restore_are_independent
    write(0x28, 0xf0, sample: 123)
    state = @chip.dump_state
    copy = RubyPlayer::Vgm::Chips::Ym2612.new(clock_hz: 7_670_454)
    copy.restore_state(state)

    assert_equal @chip.snapshot(sample: 123), copy.snapshot(sample: 123)
    assert_raises(FrozenError) { state[:registers][0][0x28] = 0 }
  end

  private

  def write(register, value, sample: 0, port: 0)
    @chip.write(port: port, register: register, value: value, sample: sample)
  end
end
