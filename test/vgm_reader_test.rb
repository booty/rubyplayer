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

    assert_equal %i[stereo_write psg_write register_write register_write wait wait_override
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

  # Regression: every non-OPLL FM write was labelled :ym2612_write and only
  # 0x53 decoded as port 1, so YM2608/YM2610/YMF262 port-1 writes read as port 0.
  def test_fm_writes_use_a_generic_kind_and_port_from_two_port_opcode_parity
    bytes = VgmBuilder.new.raw_command("\x57\x10\x01\x56\x10\x02\x59\x10\x03\x5f\x10\x04" \
                                       "\xa7\x10\x05\x54\x10\x06\x55\x10\x07\x5b\x10\x08".b).end.bytes
    reader = reader_for(bytes)
    writes = []
    offset = reader.header.data_offset
    while (command = reader.command_at(offset)).kind != :end
      writes << command.arguments.values_at(:instance, :port).unshift(command.chip_id, command.kind)
      offset = command.next_offset
    end

    assert_equal [[:ym2608, :register_write, 0, 1], [:ym2608, :register_write, 0, 0],
                  [:ym2610, :register_write, 0, 1], [:ymf262, :register_write, 0, 1],
                  [:ym2608, :register_write, 1, 1], [:ym2151, :register_write, 0, 0],
                  [:ym2203, :register_write, 0, 0], [:ym3526, :register_write, 0, 0]], writes
  end

  # Regression: SN76489 feedback and shift width were gated at 1.51, although
  # the specification adds them in 1.10; only the flags byte is a 1.51 field.
  def test_sn76489_feedback_and_shift_width_are_read_from_version_1_10
    bytes = VgmBuilder.new.psg(0x90).end.bytes
    bytes[8, 4] = [0x110].pack('V')
    bytes[0x28, 4] = [0x0009, 16, 0x05].pack('vCC')
    header = reader_for(bytes).header

    assert_equal 0x0009, header.sn_feedback
    assert_equal 16, header.sn_shift_width
    assert_nil header.sn_flags
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
