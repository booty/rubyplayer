# frozen_string_literal: true

require 'zlib'

module RubyPlayer
  module Vgm
    # Reads bounded VGM/VGZ streams and decodes validated command boundaries.
    class Reader
      READ_CHUNK_BYTES = 64 * 1024
      HEADER_BYTES = 0x40
      CANCEL_CHECK_COMMAND_INTERVAL = 1_024
      private_constant :CANCEL_CHECK_COMMAND_INTERVAL

      class Cancelled < StandardError; end

      # Base error type for rejected inputs and command-stream failures.
      class ReadError < StandardError
        attr_reader :offset

        def initialize(message, offset: nil)
          @offset = offset
          super(offset ? "#{message} at byte 0x#{offset.to_s(16)}" : message)
        end
      end

      class LimitError < ReadError; end
      class HeaderError < ReadError; end
      class CommandError < ReadError; end

      Command = Data.define(:offset, :next_offset, :kind, :chip_id, :arguments)
      Header = Data.define(:version, :data_offset, :data_end, :loop_offset,
                           :total_samples, :chip_clocks, :sn_feedback,
                           :sn_shift_width, :sn_flags, :ym2612_variant,
                           :legacy_fm_clock)

      # Operand counts for commands replayed as :skip. Chip writes, waits,
      # data blocks, stream control, and the versioned 0x40-0x4E range decode
      # separately; an opcode found nowhere is unknown.
      SKIP_OPERAND_COUNTS = begin
        counts = {}
        (0x31..0x3e).each { |opcode| counts[opcode] = 1 }
        counts[0xa0] = 2
        (0xb0..0xbf).each { |opcode| counts[opcode] = 2 }
        (0xc0..0xdf).each { |opcode| counts[opcode] = 3 }
        (0xe1..0xff).each { |opcode| counts[opcode] = 4 }
        counts.freeze
      end
      STREAM_OPERAND_COUNTS = { 0x90 => 4, 0x91 => 4, 0x92 => 5,
                                0x93 => 10, 0x94 => 1, 0x95 => 4 }.freeze
      # These chips expose two register ports; their odd base opcode
      # (0x53, 0x57, 0x59, 0x5F) addresses port 1.
      TWO_PORT_CHIPS = %i[ym2612 ym2608 ym2610 ymf262].freeze

      KNOWN_WRITE_CHIPS = {
        0x30 => :sn76489, 0x3f => :sn76489, 0x4f => :sn76489,
        0x50 => :sn76489, 0x51 => :ym2413, 0xa1 => :ym2413,
        0x52 => :ym2612, 0x53 => :ym2612, 0xa2 => :ym2612, 0xa3 => :ym2612,
        0x54 => :ym2151, 0xa4 => :ym2151,
        0x55 => :ym2203, 0xa5 => :ym2203,
        0x56 => :ym2608, 0x57 => :ym2608, 0xa6 => :ym2608, 0xa7 => :ym2608,
        0x58 => :ym2610, 0x59 => :ym2610, 0xa8 => :ym2610, 0xa9 => :ym2610,
        0x5a => :ym3812, 0xaa => :ym3812, 0x5b => :ym3526, 0xab => :ym3526,
        0x5c => :y8950, 0xac => :y8950, 0x5d => :ymz280b, 0xad => :ymz280b,
        0x5e => :ymf262, 0x5f => :ymf262, 0xae => :ymf262, 0xaf => :ymf262
      }.freeze
      # Chip identifiers follow the VGM specification, including X1-010.
      # rubocop:disable Naming/VariableNumber
      CLOCK_FIELDS = {
        sn76489: [0x0c, 0x000], ym2413: [0x10, 0x110], ym2612: [0x2c, 0x110],
        ym2151: [0x30, 0x110], sega_pcm: [0x38, 0x151],
        rf5c68: [0x40, 0x151], ym2203: [0x44, 0x151], ym2608: [0x48, 0x151],
        ym2610: [0x4c, 0x151], ym3812: [0x50, 0x151], ym3526: [0x54, 0x151],
        y8950: [0x58, 0x151], ymf262: [0x5c, 0x151], ymf278b: [0x60, 0x151],
        ymf271: [0x64, 0x151], ymz280b: [0x68, 0x151], rf5c164: [0x6c, 0x151],
        pwm: [0x70, 0x151], ay8910: [0x74, 0x151], gameboy: [0x80, 0x151],
        nes_apu: [0x84, 0x151], multipcm: [0x88, 0x151], upd7759: [0x8c, 0x151],
        okim6258: [0x90, 0x151], okim6295: [0x98, 0x151], k051649: [0x9c, 0x151],
        k054539: [0xa0, 0x151], huc6280: [0xa4, 0x151], c140: [0xa8, 0x151],
        k053260: [0xac, 0x151], pokey: [0xb0, 0x151], qsound: [0xb4, 0x151],
        scsp: [0xb8, 0x151], wonderswan: [0xc0, 0x151], vsu: [0xc4, 0x151],
        saa1099: [0xc8, 0x151], es5503: [0xcc, 0x151], es5506: [0xd0, 0x151],
        x1_010: [0xd8, 0x160], c352: [0xdc, 0x160], ga20: [0xe0, 0x161]
      }.freeze
      # rubocop:enable Naming/VariableNumber

      attr_reader :header, :bytes

      def self.vgm_stream?(path)
        File.open(path, 'rb') do |file|
          prefix = file.read(4)
          return true if prefix == 'Vgm '.b
          return false unless prefix&.start_with?("\x1f\x8b".b)

          file.rewind
          Zlib::GzipReader.wrap(file) { |gzip| gzip.read(4) == 'Vgm '.b }
        end
      rescue Zlib::Error, IOError, SystemCallError
        false
      end

      def self.open(path, max_bytes:, cancel: nil)
        new(load_bytes(path, max_bytes: max_bytes, cancel: cancel), cancel: cancel)
      end

      def self.load_bytes(path, max_bytes:, cancel: nil)
        raise ArgumentError, 'max_bytes must be a positive Integer' unless max_bytes.is_a?(Integer) && max_bytes.positive?

        File.open(path, 'rb') do |file|
          prefix = file.read(2)
          file.rewind
          buffer = +''.b
          if prefix == "\x1f\x8b".b
            gzip = Zlib::GzipReader.new(file)
            begin
              read_bounded(gzip, buffer, max_bytes, cancel)
            ensure
              gzip.close
            end
          else
            read_bounded(file, buffer, max_bytes, cancel)
          end
          buffer.freeze
        end
      rescue Zlib::Error, EOFError => e
        raise ReadError, "invalid compressed VGM data: #{e.message}"
      end

      def self.read_bounded(io, buffer, max_bytes, cancel)
        loop do
          raise Cancelled if cancel&.call

          remaining = max_bytes - buffer.bytesize
          chunk = io.read([READ_CHUNK_BYTES, remaining + 1].min)
          break if chunk.nil? || chunk.empty?
          raise LimitError, "VGM stream exceeds #{max_bytes} bytes" if chunk.bytesize > remaining

          buffer << chunk
        end
      end
      private_class_method :read_bounded

      def initialize(bytes, cancel: nil)
        @bytes = bytes
        @cancel = cancel
        @header = parse_header
        validate_stream!
      end

      def command_at(offset)
        unless offset.is_a?(Integer) && offset >= header.data_offset && offset < header.data_end
          raise CommandError.new('command offset is outside VGM data', offset: offset)
        end

        opcode = byte_at(offset)
        case opcode
        when 0x61
          command(offset, 3, :wait, nil, opcode: opcode, samples: u16(offset + 1))
        when 0x62
          command(offset, 1, :wait, nil, opcode: opcode, samples: 735)
        when 0x63
          command(offset, 1, :wait, nil, opcode: opcode, samples: 882)
        when 0x64
          command(offset, 4, :wait_override, nil,
                  command: byte_at(offset + 1), samples: u16(offset + 2))
        when 0x66
          command(offset, 1, :end, nil, {})
        when 0x67
          decode_data_block(offset)
        when 0x68
          decode_pcm_ram_write(offset)
        when 0x70..0x7f
          command(offset, 1, :wait, nil, opcode: opcode, samples: (opcode & 0x0f) + 1)
        when 0x80..0x8f
          command(offset, 1, :dac_write, :ym2612,
                  instance: 0, wait_samples: opcode & 0x0f)
        when 0x90..0x95
          decode_stream_command(offset, opcode)
        when 0xe0
          command(offset, 5, :pcm_seek, :ym2612, address: u32(offset + 1))
        else
          decode_fixed_command(offset, opcode)
        end
      end

      private

      def parse_header
        validate_header_prefix!
        version = u32(0x08)
        data_end, data_offset, loop_offset = header_offsets(version)
        build_header(version, data_end, data_offset, loop_offset)
      rescue CommandError => e
        raise HeaderError, e.message
      end

      def validate_header_prefix!
        raise HeaderError, 'VGM header is shorter than 64 bytes' if bytes.bytesize < HEADER_BYTES
        raise HeaderError, 'missing Vgm signature' unless bytes.byteslice(0, 4) == 'Vgm '.b
      end

      def header_offsets(version)
        eof_offset = u32(0x04)
        data_end = eof_offset.zero? ? bytes.bytesize : 4 + eof_offset
        raise HeaderError, 'EOF offset is outside the input' unless data_end.between?(HEADER_BYTES, bytes.bytesize)

        data_relative = version >= 0x150 ? u32(0x34) : 0
        data_offset = data_relative.zero? ? HEADER_BYTES : 0x34 + data_relative
        raise HeaderError, 'VGM data offset is outside the input' unless data_offset.between?(HEADER_BYTES, data_end - 1)

        loop_relative = u32(0x1c)
        loop_offset = loop_relative.zero? ? nil : 0x1c + loop_relative
        raise HeaderError, 'loop offset is outside VGM data' if loop_offset && !loop_offset.between?(data_offset, data_end - 1)

        [data_end, data_offset, loop_offset]
      end

      def build_header(version, data_end, data_offset, loop_offset)
        clocks = read_clock_fields(version, data_offset)
        ym2612_clock = clocks[:ym2612]&.fetch(:raw)
        Header.new(
          version: version,
          data_offset: data_offset,
          data_end: data_end,
          loop_offset: loop_offset,
          total_samples: version >= 0x101 ? u32(0x18) : nil,
          chip_clocks: freeze_nested(clocks.transform_values { |clock| clock && clock.except(:raw) }),
          sn_feedback: version >= 0x110 ? u16(0x28) : nil,
          sn_shift_width: version >= 0x110 ? byte_at(0x2a) : nil,
          sn_flags: version >= 0x151 ? byte_at(0x2b) : nil,
          ym2612_variant: ym2612_clock&.anybits?(0x8000_0000) ? :ym3438 : (ym2612_clock && :ym2612),
          legacy_fm_clock: legacy_fm_clock(version, data_offset)
        ).freeze
      end

      def legacy_fm_clock(version, data_offset)
        return unless version < 0x110 && data_offset >= 0x14

        clock = decode_clock(u32(0x10))
        freeze_nested(clock.except(:raw)) if clock
      end

      def decode_clock(value)
        return nil if value.zero?

        { raw: value, clock_hz: value & 0x3fff_ffff,
          dual: value.anybits?(0x4000_0000),
          variant_flag: value.anybits?(0x8000_0000) }
      end

      def read_clock_fields(version, data_offset)
        CLOCK_FIELDS.each_with_object({}) do |(name, (offset, minimum_version)), clocks|
          next if version < minimum_version || offset + 4 > data_offset

          raw = u32(offset)
          decoded = decode_clock(raw)
          clocks[name] = decoded if decoded
        end
      end

      def validate_stream!
        offset = header.data_offset
        found_loop = header.loop_offset.nil?
        found_end = false
        command_count = 0
        while offset < header.data_end
          raise Cancelled if (command_count % CANCEL_CHECK_COMMAND_INTERVAL).zero? && @cancel&.call

          found_loop = true if header.loop_offset == offset
          command = command_at(offset)
          raise CommandError.new('command does not advance the stream', offset: offset) if command.next_offset <= offset

          offset = command.next_offset
          command_count += 1
          if command.kind == :end
            found_end = true
            break
          end
        end
        raise Cancelled if @cancel&.call
        raise CommandError.new('VGM command stream has no end marker', offset: offset) unless found_end
        raise HeaderError, 'loop offset is not on a command boundary' unless found_loop
      end

      def decode_fixed_command(offset, opcode)
        if (0x40..0x4e).cover?(opcode)
          count = header.version >= 0x160 ? 2 : 1
          return decode_skip(offset, opcode, count)
        end

        if (chip = KNOWN_WRITE_CHIPS[opcode])
          return decode_chip_write(offset, opcode, chip)
        end

        count = SKIP_OPERAND_COUNTS[opcode]
        raise CommandError.new(format('unknown command 0x%02x', opcode), offset: offset) unless count

        decode_skip(offset, opcode, count)
      end

      def decode_chip_write(offset, opcode, chip)
        if chip == :sn76489
          kind = [0x3f, 0x4f].include?(opcode) ? :stereo_write : :psg_write
          instance = [0x30, 0x3f].include?(opcode) ? 1 : 0
          return command(offset, 2, kind, chip, instance: instance,
                                                value: byte_at(offset + 1))
        end

        instance = opcode >= 0xa0 ? 1 : 0
        base_opcode = opcode >= 0xa0 ? opcode - 0x50 : opcode
        port = TWO_PORT_CHIPS.include?(chip) && base_opcode.odd? ? 1 : 0
        register = byte_at(offset + 1)
        value = byte_at(offset + 2)
        command(offset, 3, :register_write, chip, instance: instance, port: port,
                                                  register: register, value: value)
      end

      def decode_skip(offset, opcode, count)
        operands = byteslice(offset + 1, count, offset)
        command(offset, count + 1, :skip, nil,
                opcode: opcode, operands: operands)
      end

      def decode_data_block(offset)
        require_bytes(offset, 7)
        marker = byte_at(offset + 1)
        raise CommandError.new('invalid data-block marker', offset: offset) unless marker == 0x66

        type = byte_at(offset + 2)
        size = u32(offset + 3)
        payload_offset = offset + 7
        next_offset = payload_offset + size
        raise CommandError.new('data block exceeds VGM data bounds', offset: offset) if next_offset > header.data_end

        command(offset, next_offset - offset, :data_block, nil,
                type: type, size: size, data_offset: payload_offset)
      end

      def decode_pcm_ram_write(offset)
        require_bytes(offset, 12)
        raise CommandError.new('invalid PCM RAM write marker', offset: offset) unless byte_at(offset + 1) == 0x66

        command(offset, 12, :pcm_ram_write, nil,
                chip_type: byte_at(offset + 2),
                read_offset: u24(offset + 3),
                write_offset: u24(offset + 6),
                size: u24(offset + 9))
      end

      def decode_stream_command(offset, opcode)
        count = STREAM_OPERAND_COUNTS.fetch(opcode)
        operands = byteslice(offset + 1, count, offset)
        command(offset, count + 1, :stream_command, nil,
                opcode: opcode, operands: operands)
      end

      def command(offset, size, kind, chip_id, arguments = {})
        require_bytes(offset, size)
        Command.new(offset: offset, next_offset: offset + size, kind: kind,
                    chip_id: chip_id, arguments: freeze_nested(arguments)).freeze
      end

      def require_bytes(offset, size)
        return if size >= 0 && offset + size <= header.data_end

        raise CommandError.new('truncated command operands', offset: offset)
      end

      def byte_at(offset)
        value = bytes.getbyte(offset)
        raise CommandError.new('truncated command operands', offset: offset) unless value

        value
      end

      def u16(offset)
        byteslice(offset, 2, offset).unpack1('v')
      end

      def u24(offset)
        b0, b1, b2 = byteslice(offset, 3, offset).unpack('C*')
        b0 | (b1 << 8) | (b2 << 16)
      end

      def u32(offset)
        byteslice(offset, 4, offset).unpack1('V')
      end

      def byteslice(start, length, error_offset)
        slice = bytes.byteslice(start, length)
        return slice if slice && slice.bytesize == length

        raise CommandError.new('truncated command operands', offset: error_offset)
      end

      def freeze_nested(value)
        case value
        when Hash
          value.each do |key, item|
            freeze_nested(key)
            freeze_nested(item)
          end
        when Array
          value.each { |item| freeze_nested(item) }
        when String
          value.freeze
        end
        value.freeze
      end
    end
  end
end
