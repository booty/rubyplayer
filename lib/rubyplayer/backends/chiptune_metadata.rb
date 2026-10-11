# frozen_string_literal: true

require 'zlib'
require_relative 'metadata_helper'

module RubyPlayer
  module Backends
    # Header facts and hardware capabilities, never current voice activity.
    module ChiptuneMetadata
      HEADER_BYTES = 512
      NSFE_CHUNK_LIMIT = 128
      PROFILES = {
        'gbs' => ['Game Boy APU', '2 pulse + 1 wave + 1 noise'],
        'spc' => ['S-DSP', '8 sample voices'],
        'hes' => ['HuC6280 PSG', '6 wavetable (2 also support noise)'],
        'gym' => ['YM2612 + SN76489', '6 FM (FM 6 can use PCM); 3 tone + 1 noise'],
        'ay' => ['AY-3-8910 + beeper', '3 tone with shared noise/envelope + beeper']
      }.freeze
      EXPANSIONS = %w[VRC6 VRC7 FDS MMC5 N163 S5B].freeze
      VGM_CHIPS = [
        [0x0c, 'SN76489', '3 tone + 1 noise'],
        [0x10, 'YM2413', '9 FM (rhythm mode available)'],
        [0x2c, 'YM2612', '6 FM (FM 6 can use PCM)'],
        [0x30, 'YM2151', '8 FM']
      ].freeze
      private_constant :HEADER_BYTES, :NSFE_CHUNK_LIMIT, :PROFILES, :EXPANSIONS, :VGM_CHIPS

      module_function

      def read(path)
        extension = MetadataHelper.format_extension(path)
        return hardware(*PROFILES.fetch(extension)) if PROFILES.key?(extension)

        File.open(path, 'rb') do |file|
          parse(extension, file, read_header(file)) || {}
        end
      rescue SystemCallError, IOError, Zlib::Error
        # Optional header facts must not prevent otherwise playable metadata.
        {}
      end

      def read_header(file)
        compressed = file.read(2) == "\x1f\x8b".b
        file.rewind
        return Zlib::GzipReader.wrap(file) { |gzip| gzip.read(HEADER_BYTES).to_s } if compressed

        file.read(HEADER_BYTES).to_s
      end

      def parse(extension, file, header)
        case extension
        when 'vgm', 'vgz' then vgm(header)
        when 'nsf' then nsf(header.getbyte(0x7b)) if header.start_with?("NESM\x1a")
        when 'nsfe' then nsfe(file) if header.start_with?('NSFE')
        when 'sap' then sap(header) if header.start_with?("SAP\r\n", "SAP\n")
        when 'kss' then kss(header.getbyte(15)) if header.start_with?('KSCC', 'KSSX')
        end
      end

      def hardware(chips, voices)
        { 'sound_chips' => chips, 'voice_layout' => voices }
      end

      def nsf(flags)
        return {} unless flags

        chips = ['NES APU'] + EXPANSIONS.each_with_index.filter_map { |name, bit| name if flags[bit] == 1 }
        suffix = chips.size > 1 ? '; expansion voices' : ''
        hardware(chips.join(' + '), "2 pulse + 1 triangle + 1 noise + 1 DMC#{suffix}")
      end

      def nsfe(file)
        file.seek(4)
        NSFE_CHUNK_LIMIT.times do
          chunk = file.read(8)
          break unless chunk&.bytesize == 8

          size = chunk.unpack1('V')
          break if file.pos + size > file.size
          return nsf(file.read([size, 8].min).getbyte(7)) if chunk[4, 4] == 'INFO'
          break if chunk[4, 4] == 'NEND'

          file.seek(size, IO::SEEK_CUR)
        end
        {}
      end

      def sap(header)
        stereo = header.split("\xff\xff".b, 2).first.lines.any? { |line| line.strip == 'STEREO' }
        hardware(stereo ? '2 x POKEY' : 'POKEY', stereo ? '8 tone/noise voices' : '4 tone/noise voices')
      end

      def kss(flags)
        return {} unless flags
        return hardware('SN76489', '3 tone + 1 noise') if flags[1] == 1

        chips = ['AY-3-8910']
        chips << 'SCC (available)' if flags[2].zero?
        chips << 'YM2413 (declared)' if flags[0] == 1
        chips << 'Y8950 (declared)' if flags[3] == 1
        hardware(chips.join(' + '), '3 tone with shared noise/envelope; optional expansion voices')
      end

      def vgm(header)
        return {} unless header.bytesize >= 0x40 && header.start_with?('Vgm ')

        version = header[8, 4].unpack1('V')
        chips = VGM_CHIPS.filter_map { |chip| vgm_chip(header, version, *chip) }
        hardware(chips.map(&:first).join(' + '), chips.map { |chip| chip[1] }.join('; ')).merge(
          'vgm_version' => format('%x.%02x', version >> 8, version & 0xff),
          'chip_clocks' => chips.map(&:last).join('; ')
        )
      end

      def vgm_chip(header, version, offset, name, layout)
        return if version < 0x110 && offset >= 0x2c

        raw = header[offset, 4].unpack1('V')
        clock = raw & 0x3fffffff
        return if clock.zero?

        # Early VGM reused the OPLL clock field for the actual FM chip.
        name, layout = legacy_fm_layout(clock) if version < 0x110 && offset == 0x10
        return ['T6W28', 'PSG tone/noise (stereo)', "T6W28 #{clock} Hz"] if offset == 0x0c && raw.allbits?(0xc0000000)

        name = 'YM3438' if offset == 0x2c && raw.anybits?(0x80000000)
        prefix = raw.anybits?(0x40000000) ? '2 x ' : ''
        ["#{prefix}#{name}", "#{prefix}#{layout}", "#{name} #{clock} Hz"]
      end

      def legacy_fm_layout(clock)
        # Lower clock rates cannot distinguish OPLL from OPM without commands.
        clock > 5_000_000 ? VGM_CHIPS[2][1..] : ['Legacy FM', 'FM voices']
      end
    end
  end
end
