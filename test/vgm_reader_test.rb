# frozen_string_literal: true

require 'test_helper'
require 'tempfile'
require_relative 'support/vgm_builder'
require 'rubyplayer/vgm/reader'

class VgmReaderTest < Minitest::Test
  Vgm = RubyPlayer::Vgm

  def test_plain_and_gzip_streams_produce_the_same_commands
    bytes = VgmBuilder.new.psg(0x90).wait(735).ym2612(0, 0x2a, 0x77).end.bytes
    plain = reader_for(bytes)
    gzip = reader_for(VgmBuilder.new.psg(0x90).wait(735).ym2612(0, 0x2a, 0x77).end.gzip)

    assert_equal command_values(plain), command_values(gzip)
    assert_equal 0x40, plain.header.data_offset
  end

  def test_nondefault_data_offset_is_relative_to_its_header_field
    bytes = VgmBuilder.new.psg(0x90).end.bytes
    extension = "\0" * 24
    data_offset = 0x40 + extension.bytesize
    bytes.insert(0x40, extension)
    bytes[0x34, 4] = [data_offset - 0x34].pack('V')
    bytes[4, 4] = [bytes.bytesize - 4].pack('V')

    reader = reader_for(bytes)

    assert_equal data_offset, reader.header.data_offset
    assert_equal :psg_write, reader.command_at(data_offset).kind
  end

  def test_data_block_is_skipped_without_parsing_its_payload_as_commands
    bytes = VgmBuilder.new.data_block(type: 0x7f, data: "\x50\xff\x61\x01\x00")
                      .psg(0x90).end.bytes
    reader = reader_for(bytes)
    block = reader.command_at(reader.header.data_offset)
    following = reader.command_at(block.next_offset)

    assert_equal :data_block, block.kind
    assert_equal 5, block.arguments.fetch(:size)
    assert_equal :psg_write, following.kind
    assert_equal 0x90, following.arguments.fetch(:value)
  end

  def test_decodes_fixed_and_variable_command_sizes
    builder = VgmBuilder.new.psg_stereo(0xc0).psg(0x90).ym2413(0x20, 0x19)
                        .ym2612(1, 0x28, 0xf0).wait(735).wait_override(command: 0x62, samples: 800)
                        .dac_wait(3).pcm_seek(0x123456).data_block(type: 0, data: 'PCM')
    reader = reader_for(builder.end.bytes)
    commands = []
    offset = reader.header.data_offset
    loop do
      command = reader.command_at(offset)
      commands << command
      break if command.kind == :end

      offset = command.next_offset
    end

    assert_equal %i[stereo_write psg_write ym2413_write ym2612_write wait wait_override
                    dac_write pcm_seek data_block end], commands.map(&:kind)
    seek_addresses = commands.grep(Vgm::Reader::Command)
                             .select { |command| command.kind == :pcm_seek }
                             .map { |command| command.arguments.fetch(:address) }

    assert_equal [0x123456], seek_addresses
  end

  def test_rejects_loop_pointer_that_lands_inside_a_command
    bytes = VgmBuilder.new.psg(0x90).wait(1).end.bytes
    bytes[0x1c, 4] = [0x40 + 1 - 0x1c].pack('V')

    error = assert_raises(Vgm::Reader::HeaderError) { reader_for(bytes) }
    assert_match(/loop.*command boundary/i, error.message)
  end

  def test_rejects_truncated_operands_unknown_commands_and_missing_end
    truncated = VgmBuilder.new.raw_command("\x52\x2a".b).end.bytes
    truncated.slice!(-1, 1) # remove the end marker, leaving YM2612 write incomplete
    truncated[4, 4] = [truncated.bytesize - 4].pack('V')
    assert_raises(Vgm::Reader::CommandError) { reader_for(truncated) }

    unknown = VgmBuilder.new.raw_command("\xf0".b).end.bytes
    assert_raises(Vgm::Reader::CommandError) { reader_for(unknown) }

    no_end = VgmBuilder.new.psg(0x90).bytes
    no_end.slice!(-1, 1)
    no_end[4, 4] = [no_end.bytesize - 4].pack('V')
    assert_raises(Vgm::Reader::CommandError) { reader_for(no_end) }
  end

  def test_decompression_limit_is_enforced_before_appending_oversized_content
    bytes = VgmBuilder.new.data_block(type: 0, data: 'x' * 2_000).end.gzip

    error = with_file(bytes) do |path|
      assert_raises(Vgm::Reader::LimitError) { Vgm::Reader.open(path, max_bytes: 1_100) }
    end

    assert_match(/exceeds 1100 bytes/, error.message)
  end

  def test_open_can_cancel_during_command_validation
    bytes = VgmBuilder.new.raw_command("\x70".b * 10_000).end.bytes
    checks = 0
    cancel = lambda do
      checks += 1
      checks >= 4
    end

    error = with_file(bytes) do |path|
      assert_raises(Vgm::Reader::Cancelled) do
        Vgm::Reader.open(path, max_bytes: 65_536, cancel: cancel)
      end
    end

    assert_operator checks, :>=, 4
    assert_instance_of Vgm::Reader::Cancelled, error
  end

  def test_pre_1_10_opll_clock_field_is_kept_as_ambiguous_legacy_fm
    bytes = VgmBuilder.new(ym2413_clock: 3_579_545).ym2413(0x20, 0x10).end.bytes
    bytes[8, 4] = [0x101].pack('V')

    reader = reader_for(bytes)

    refute reader.header.chip_clocks.key?(:ym2413)
    assert_equal 3_579_545, reader.header.legacy_fm_clock.fetch(:clock_hz)
  end

  private

  def reader_for(bytes)
    with_file(bytes) { |path| Vgm::Reader.open(path, max_bytes: 65_536) }
  end

  def command_values(reader)
    values = []
    offset = reader.header.data_offset
    loop do
      command = reader.command_at(offset)
      values << [command.offset, command.next_offset, command.kind,
                 command.chip_id, command.arguments]
      break if command.kind == :end

      offset = command.next_offset
    end
    values
  end

  def with_file(bytes)
    Tempfile.create(['rubyplayer-reader', '.bin']) do |file|
      file.binmode
      file.write(bytes)
      file.flush
      yield file.path
    end
  end
end
