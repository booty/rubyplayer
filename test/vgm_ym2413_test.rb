# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/pitch'
require 'rubyplayer/vgm/patch'
require 'rubyplayer/vgm/chips/ym2413'

class VgmYm2413Test < Minitest::Test
  def setup
    @chip = RubyPlayer::Vgm::Chips::Ym2413.new(clock_hz: 3_579_545)
  end

  def test_melodic_program_volume_key_sustain_and_frequency
    write(0x30, 0x35)
    write(0x10, 0x60)
    write(0x20, 0x30 | 0x10 | 1)
    row = @chip.snapshot(sample: 0).channels.first

    assert_equal :key_on, row.state
    assert_equal 3, row.details.fetch(:program_number)
    assert_equal 5, row.details.fetch(:volume)
    assert row.details.fetch(:sustain)
    assert_operator row.pitch_hz, :>, 0
    assert_equal :lr, row.pan
    assert_equal 64, row.last_trigger_sample
  end

  def test_custom_patch_is_shared_by_every_channel_selecting_program_zero
    [0xf3, 0xe2, 0xa5, 0xb9, 0xc4, 0xd6, 0xa7, 0x8b].each_with_index do |value, register|
      write(register, value)
    end
    write(0x30, 0x07)
    write(0x31, 0x0b)
    before = @chip.snapshot(sample: 0).channels.first(2)
    write(0x02, 0x1f)
    after = @chip.snapshot(sample: 0).channels.first(2)

    assert_equal :custom, before[0].details.fetch(:program_number)
    assert_equal before[0].patch.digest, before[1].patch.digest
    refute_equal before[0].patch.digest, after[0].patch.digest
    assert_equal after[0].patch.digest, after[1].patch.digest
    assert_equal [1, 2], after[0].patch.operators.map(&:index)
    assert_equal [1, 1, 12, 7], after[0].patch.operators.first.parameters.values_at(:am, :pm, :ar, :rr)
  end

  def test_rhythm_mode_replaces_channels_six_to_eight_with_percussion_roles
    write(0x0e, 0x20 | 0x1f, sample: 100)
    rows = @chip.snapshot(sample: 120).channels

    assert_equal :percussion, rows[6].kind
    assert_equal [:bass_drum], rows[6].details.fetch(:roles)
    assert_equal %i[hi_hat snare], rows[7].details.fetch(:roles)
    assert_equal %i[tom cymbal], rows[8].details.fetch(:roles)
    assert_equal 100, rows[6].last_trigger_sample
    assert rows[6].details.fetch(:rhythm_mode)
  end

  def test_turning_rhythm_off_restores_melodic_roles_with_stable_ids
    write(0x0e, 0x3f)
    percussion_id = @chip.snapshot(sample: 0).channels[6].id
    write(0x0e, 0x00)
    row = @chip.snapshot(sample: 1).channels[6]

    assert_equal percussion_id, row.id
    assert_equal :tone, row.kind
    assert_equal :key_off, row.state
  end

  def test_second_opll_instance_is_independent
    second = RubyPlayer::Vgm::Chips::Ym2413.new(clock_hz: 3_579_545, instance: 1)
    write(0x30, 0x20)
    second.write(port: 0, register: 0x30, value: 0x70, sample: 0)

    assert_equal 2, @chip.snapshot(sample: 0).channels.first.details.fetch(:program_number)
    assert_equal 7, second.snapshot(sample: 0).channels.first.details.fetch(:program_number)
    refute_equal @chip.snapshot(sample: 0).channels.first.patch.digest,
                 second.snapshot(sample: 0).channels.first.patch.digest
  end

  def test_history_and_rom_instrument_names
    write(0x30, 0x30)
    write(0x10, 0xac)
    write(0x20, 0x18, sample: 100)
    write(0x10, 0x20, sample: 150)
    write(0x20, 0x08, sample: 200)
    write(0x0e, 0x30, sample: 250)
    snapshot = @chip.snapshot(sample: 300)
    events = RubyPlayer::Vgm::NoteLog.decode(snapshot.details.fetch(:events))

    assert_equal 'Piano', snapshot.channels.first.details.fetch(:program_name)
    assert_equal([[0, :on, 100], [0, :note, 150], [0, :off, 200], [6, :on, 250]],
                 events.map { |event| [event.channel, event.kind, event.sample] })
  end

  private

  def write(register, value, sample: 64)
    @chip.write(port: 0, register: register, value: value, sample: sample)
  end
end
