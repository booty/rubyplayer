# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/pitch'
require 'rubyplayer/vgm/patch'
require 'rubyplayer/vgm/chips/ym2612'
require 'rubyplayer/vgm/note_log'

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
    # Regression: pitch used 2^block / 2^20 and labelled every FM note one
    # octave high. The OPN2 formula is fnum * clock * 2^(block-1) / (144 * 2^20).
    assert_in_delta 247.0883, first.pitch_hz, 0.001
    assert_equal 'B3', first.note
    assert_equal 4, first.patch.algorithm
    assert_equal 6, first.patch.feedback
    assert_equal :lr, first.pan
    assert_equal digest, same_timbre.patch.digest
    refute_equal digest, changed_timbre.patch.digest
  end

  def test_channel_three_special_mode_reports_operator_pitches
    write(0x27, 0x40)
    write(0xac, 0x12)
    write(0xa8, 0x34)
    row = @chip.snapshot(sample: 0).channels.fetch(2)

    assert_equal :special, row.note
    assert_nil row.pitch_hz
    assert_equal 0x234, special_operator(row, 3).fetch(:fnum)
  end

  # Regression: A8/A9/AA were labelled OP1/OP2/OP3 and OP4 was omitted. On the
  # chip A9 drives OP1, AA drives OP2, A8 drives OP3, and A2 (the normal channel
  # 3 frequency) drives OP4.
  def test_special_mode_maps_each_frequency_register_to_its_hardware_operator
    write(0x27, 0x40)
    { 0xa9 => [0x11, 0x01], 0xaa => [0x12, 0x02], 0xa8 => [0x13, 0x03] }.each do |register, (high, low)|
      write(register + 4, high)
      write(register, low)
    end
    write(0xa6, 0x14)
    write(0xa2, 0x04)
    rows = @chip.snapshot(sample: 0).channels.fetch(2).details.fetch(:special_frequencies)

    assert_equal([1, 2, 3, 4], rows.map { |item| item.fetch(:operator) })
    assert_equal([0x101, 0x202, 0x303, 0x404], rows.map { |item| item.fetch(:fnum) })
    assert_equal([2, 2, 2, 2], rows.map { |item| item.fetch(:block) })
    assert(rows.all? { |item| item.fetch(:pitch_hz).positive? })
  end

  # The high-byte latch is shared by every channel (and by both ports); only the
  # low-byte write commits a frequency. Per-channel latches diverged from libgme
  # when a driver wrote A4 for one channel and committed A1 for another.
  def test_frequency_high_latch_is_shared_across_channels_and_ports
    write(0xa4, 0x22)
    write(0xa1, 0x60)
    write(0xa5, 0x13, port: 1)
    write(0xa0, 0x10)
    rows = @chip.snapshot(sample: 0).channels

    assert_equal({ fnum: 0x260, block: 4 }, rows.fetch(1).details.fetch(:frequency).slice(:fnum, :block))
    assert_equal({ fnum: 0x310, block: 2 }, rows.fetch(0).details.fetch(:frequency).slice(:fnum, :block))
    assert_nil rows.fetch(5).details.fetch(:frequency)
  end

  def test_special_frequency_high_latch_commits_only_on_low_write
    write(0x27, 0x40)
    write(0xa8, 0x34)
    write(0xac, 0x12)
    row = @chip.snapshot(sample: 0).channels.fetch(2)

    assert_equal 0x034, special_operator(row, 3).fetch(:fnum)
    assert_equal 0, special_operator(row, 3).fetch(:block)
  end

  def test_unchanged_registers_reuse_the_patch_object
    write(0xb0, 0x34)
    first = @chip.snapshot(sample: 0).channels.first.patch
    write(0x28, 0xf0, sample: 1)
    second = @chip.snapshot(sample: 1).channels.first.patch
    write(0x40, 9)
    third = @chip.snapshot(sample: 2).channels.first.patch

    assert_same first, second
    refute_same first, third
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
    write(0xac, 0x12)
    write(0xa8, 0x34)
    write(0x28, 0x00, sample: 2, port: 1)
    write(0x2b, 0x00, port: 1)
    write(0x27, 0x00, port: 1)
    write(0xa8, 0x00, port: 1)
    write(0xac, 0x00, port: 1)
    before_mode = @chip.snapshot(sample: 2)

    assert_equal :key_on, before_mode.channels.first.state
    assert before_mode.details.fetch(:dac_enabled)
    special = special_operator(before_mode.channels.fetch(2), 3)

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

  def test_history_records_note_starts_pitch_changes_and_releases
    write(0xa4, 0x22)
    write(0xa0, 0x69)
    write(0x28, 0xf0, sample: 100)
    write(0xa4, 0x22)
    write(0xa0, 0xa0, sample: 200)
    write(0x28, 0x00, sample: 300)
    snapshot = @chip.snapshot(sample: 300)
    events = RubyPlayer::Vgm::NoteLog.decode(snapshot.details.fetch(:events))

    assert_equal %i[on note off], events.map(&:kind)
    assert_equal [100, 200, 300], events.map(&:sample)
    refute_equal events[0].midi, events[1].midi
    assert_equal 300, snapshot.channels.first.details.fetch(:release_sample)
  end

  def test_operators_key_on_and_off_independently
    write(0x28, 0x30, sample: 100)
    write(0x28, 0xb0, sample: 200)
    write(0x28, 0x80, sample: 300)
    details = @chip.snapshot(sample: 400).channels.first.details

    assert_equal [100, 100, nil, 200], details.fetch(:operator_triggers)
    assert_equal [300, 300, nil, nil], details.fetch(:operator_releases)
  end

  # A burst's end is logged at its last DAC write, after FM events with
  # later samples; pruning past them must not fail or reorder history.
  def test_late_dac_burst_ends_survive_pruning
    write(0x2b, 0x80)
    write(0x2a, 0x90, sample: 0)
    256.times { |index| write(0x28, index.even? ? 0xf0 : 0x00, sample: index + 1) }
    write(0x2a, 0x90, sample: 10_000)
    RubyPlayer::Vgm::NoteLog::MAX_EVENTS.times do |index|
      write(0x28, index.even? ? 0xf0 : 0x00, sample: 10_001 + index)
    end
    samples = RubyPlayer::Vgm::NoteLog.decode(@chip.snapshot(sample: 20_000).details.fetch(:events)).map(&:sample)

    assert_equal samples.sort, samples
  end

  def test_dac_bursts_are_single_history_notes
    write(0x2b, 0x80)
    [10, 20, 30].each { |sample| write(0x2a, 0x90, sample: sample) }
    write(0x2a, 0x70, sample: 30 + RubyPlayer::Vgm::Chips::Ym2612::RECENT_SAMPLES + 1)
    snapshot = @chip.snapshot(sample: 10_000)
    events = RubyPlayer::Vgm::NoteLog.decode(snapshot.details.fetch(:events))

    assert_equal([[:on, 10], [:off, 30], [:on, 4_441]], events.map { |event| [event.kind, event.sample] })
    assert_equal 4, snapshot.details.fetch(:dac_writes)
  end

  def test_lfo_and_timer_rates
    write(0x22, 0x0b)
    write(0x24, 0xff)
    write(0x25, 0x03)
    write(0x26, 0xf0)
    write(0x27, 0x03)
    details = @chip.snapshot(sample: 0).details

    assert_in_delta 6.37, details.fetch(:lfo_hz), 0.001
    assert_in_delta 7_670_454 / 144.0, details.fetch(:timer_a_hz), 0.01
    assert_in_delta 7_670_454 / (144.0 * 16 * 16), details.fetch(:timer_b_hz), 0.01
    assert_equal [true, true], details.fetch(:timers_running)
  end

  private

  def special_operator(row, operator)
    row.details.fetch(:special_frequencies).find { |item| item.fetch(:operator) == operator }
  end

  def write(register, value, sample: 0, port: 0)
    @chip.write(port: port, register: register, value: value, sample: sample)
  end
end
