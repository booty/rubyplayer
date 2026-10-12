# frozen_string_literal: true

require 'test_helper'
require 'tempfile'
require_relative 'support/vgm_builder'
require 'rubyplayer/vgm/reader'
require 'rubyplayer/vgm/chips'

class VgmChipsTest < Minitest::Test
  def test_mixed_psg_and_ym2612_rows_are_routed_separately
    reader = reader_for(VgmBuilder.new(ym2612_clock: 7_670_454)
      .psg(0x90).ym2612(0, 0x28, 0xf0).end.bytes)
    chips = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header)
    commands = read_commands(reader)
    commands.each { |command| chips.write(command: command, sample: 0) }
    result = chips.snapshot(sample: 0)

    assert_equal :ready, result.fetch(:status)
    assert_equal %w[sn76489:0 ym2612:0], result.fetch(:chips).map(&:id)
    assert_equal :enabled, result.fetch(:chips)[0].channels[0].state
    assert_equal :key_on, result.fetch(:chips)[1].channels[0].state
  end

  def test_ym3438_uses_the_shared_model_with_declared_label_and_dual_instances
    reader = reader_for(VgmBuilder.new(ym2612_clock: 0xc000_0000 | 7_670_454)
      .raw_command("\xa2\x28\xf0".b).end.bytes)
    chips = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header)
    read_commands(reader).each { |command| chips.write(command: command, sample: 1) }
    snapshots = chips.snapshot(sample: 1).fetch(:chips).select { |chip| chip.id.start_with?('ym2612:') }

    assert_equal 2, snapshots.size
    assert_equal 'YM3438', snapshots.first.name
    assert_equal :key_off, snapshots[0].channels.first.state
    assert_equal :key_on, snapshots[1].channels.first.state
    assert_equal 'ym2612:1:0', snapshots[1].channels.first.id
  end

  def test_unsupported_ym2151_and_t6w28_are_visible_without_interpreting_writes
    vgm = VgmBuilder.new(sn76489_clock: 0xc000_0000 | 3_579_545,
                         ym2151_clock: 4_000_000)
                    .raw_command("\x54\x08\x78".b).end.bytes
    reader = reader_for(vgm)
    chips = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header)
    read_commands(reader).each { |command| chips.write(command: command, sample: 10) }
    result = chips.snapshot(sample: 10)

    assert_equal :partial, result.fetch(:status)
    assert_equal(%i[unsupported unsupported], result.fetch(:chips).map { |chip| chip.details[:status] })
    assert_includes result.fetch(:warnings).join(' '), 'YM2151'
    assert_includes result.fetch(:warnings).join(' '), 'T6W28'
    assert_empty result.fetch(:chips).flat_map(&:channels)
    # A declared-but-unsupported chip already explains itself; its writes must
    # not add a second "undeclared" warning.
    refute_includes result.fetch(:warnings).join(' '), 'undeclared'
  end

  # The specification marks T6W28 with bit 31 *and* the dual-chip bit 30. Bit
  # 31 alone is an unrecognised variant: neither T6W28 nor a plain SN76489.
  def test_psg_variant_bit_without_dual_bit_is_unsupported_but_not_t6w28
    reader = reader_for(VgmBuilder.new(sn76489_clock: 0x8000_0000 | 3_579_545).psg(0x90).end.bytes)
    chips = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header)
    read_commands(reader).each { |command| chips.write(command: command, sample: 0) }
    result = chips.snapshot(sample: 0)

    assert_equal([:unsupported], result.fetch(:chips).map { |chip| chip.details[:status] })
    refute_includes result.fetch(:warnings).join(' '), 'T6W28'
    assert_includes result.fetch(:warnings).join(' '), 'variant flag'
  end

  def test_t6w28_pair_is_reported_as_one_chip
    reader = reader_for(VgmBuilder.new(sn76489_clock: 0xc000_0000 | 3_579_545).end.bytes)
    result = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header).snapshot(sample: 0)

    assert_equal ['T6W28'], result.fetch(:chips).map(&:name)
  end

  def test_t6w28_second_half_and_legacy_fm_writes_do_not_warn_undeclared
    t6w28 = reader_for(VgmBuilder.new(sn76489_clock: 0xc000_0000 | 3_579_545)
      .raw_command("\x30\x90".b).end.bytes)
    legacy = VgmBuilder.new(sn76489_clock: nil, ym2413_clock: 3_579_545).ym2413(0x20, 0x10).end.bytes
    legacy[8, 4] = [0x101].pack('V')
    warnings = [t6w28, reader_for(legacy)].flat_map do |reader|
      chips = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header)
      read_commands(reader).each { |command| chips.write(command: command, sample: 0) }
      chips.snapshot(sample: 0).fetch(:warnings)
    end

    refute_includes warnings.join(' '), 'undeclared'
  end

  def test_mixed_opll_and_ym2612_reports_libgme_coverage_limit
    reader = reader_for(VgmBuilder.new(ym2612_clock: 7_670_454, ym2413_clock: 3_579_545).end.bytes)
    result = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header).snapshot(sample: 0)

    assert_equal :partial, result.fetch(:status)
    assert(result.fetch(:warnings).any? { |warning| warning.include?('YM2413') && warning.include?('YM2612') })
  end

  def test_legacy_fm_clock_is_reported_unsupported_without_fabricating_opll_rows
    bytes = VgmBuilder.new(sn76489_clock: nil, ym2413_clock: 3_579_545)
                      .ym2413(0x20, 0x10).end.bytes
    bytes[8, 4] = [0x101].pack('V')
    reader = reader_for(bytes)
    result = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header).snapshot(sample: 0)

    assert_equal :partial, result.fetch(:status)
    assert_equal ['Legacy FM'], result.fetch(:chips).map(&:name)
    assert_empty result.fetch(:chips).flat_map(&:channels)
    assert_includes result.fetch(:warnings).join(' '), 'ambiguous legacy FM clock'
  end

  def test_pre_1_10_reserved_clock_bytes_do_not_fabricate_ym2612_rows
    bytes = VgmBuilder.new(sn76489_clock: nil).end.bytes
    bytes[8, 4] = [0x101].pack('V')
    bytes[0x2c, 4] = [7_670_454].pack('V')
    reader = reader_for(bytes)
    result = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header).snapshot(sample: 0)

    refute reader.header.chip_clocks.key?(:ym2612)
    refute(result.fetch(:chips).any? { |chip| chip.id.start_with?('ym2612:') })
  end

  def test_writes_to_undeclared_chip_instance_do_not_fabricate_rows
    reader = reader_for(VgmBuilder.new.ym2612(0, 0x28, 0xf0).end.bytes)
    chips = RubyPlayer::Vgm::ChipRegistry.new(header: reader.header)
    read_commands(reader).each { |command| chips.write(command: command, sample: 0) }

    result = chips.snapshot(sample: 0)

    refute(result.fetch(:chips).any? { |chip| chip.id == 'ym2612:0' })
    assert_equal :partial, result.fetch(:status)
    assert_includes result.fetch(:warnings).join(' '), 'undeclared'
  end

  private

  def reader_for(bytes)
    Tempfile.create(['rubyplayer-chips', '.vgm']) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      return RubyPlayer::Vgm::Reader.open(file.path, max_bytes: 65_536)
    end
  end

  def read_commands(reader)
    commands = []
    offset = reader.header.data_offset
    loop do
      command = reader.command_at(offset)
      commands << command
      break if command.kind == :end

      offset = command.next_offset
    end
    commands
  end
end
