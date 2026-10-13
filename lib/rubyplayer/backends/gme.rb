# frozen_string_literal: true

require 'ffi'
require_relative '../runtime_dependencies'
require_relative '../audio_format'
require_relative '../vgm/reader'
require_relative 'metadata_helper'
require_relative 'chiptune_metadata'

module RubyPlayer
  module Backends
    module GmeLib
      extend FFI::Library

      ffi_lib RubyPlayer::RuntimeDependencies::GME_LIBRARY_CANDIDATES

      GME_INFO_ONLY = -1 # special sample_rate: open for metadata only

      # gme functions return a const char* error string, or NULL on success.
      # gme_open_file/gme_track_info do real decoding work during scanning (parsing
      # the file, in gme_open_file's case reading it from disk); each call operates
      # on its own handle/buffer and never re-enters Ruby, so marking them blocking:
      # true lets ExtractorPool's worker threads actually run them concurrently
      # across cores instead of serializing on the GVL.
      attach_function :gme_open_file, %i[string pointer int], :string, blocking: true
      attach_function :gme_track_count, [:pointer], :int
      attach_function :gme_ignore_silence, %i[pointer int], :void
      attach_function :gme_start_track, %i[pointer int], :string
      attach_function :gme_play, %i[pointer int pointer], :string, blocking: true
      attach_function :gme_track_ended, [:pointer], :int
      attach_function :gme_seek, %i[pointer int], :string, blocking: true
      attach_function :gme_tell, [:pointer], :int
      attach_function :gme_set_fade, %i[pointer int], :void
      attach_function :gme_track_info, %i[pointer pointer int], :string, blocking: true
      attach_function :gme_free_info, [:pointer], :void
      attach_function :gme_delete, [:pointer], :void
      attach_function :gme_load_m3u, %i[pointer string], :string, blocking: true
      attach_function :gme_mute_voices, %i[pointer int], :void
    end

    # Mirrors gme_info_t: 16 ints then 16 const char*. Only the named leading
    # fields are used; i4 corresponds to gme.h's named `fade_length` field
    # (unused by our code), and i5..i15 / s7..s15 are reserved padding, so this
    # layout is size-compatible across libgme 0.6.x releases.
    class GmeInfo < FFI::Struct
      layout :length, :int, :intro_length, :int, :loop_length, :int, :play_length, :int,
             :i4, :int, :i5, :int, :i6, :int, :i7, :int, :i8, :int, :i9, :int,
             :i10, :int, :i11, :int, :i12, :int, :i13, :int, :i14, :int, :i15, :int,
             :system, :string, :game, :string, :song, :string, :author, :string,
             :copyright, :string, :comment, :string, :dumper, :string,
             :s7, :string, :s8, :string, :s9, :string, :s10, :string, :s11, :string,
             :s12, :string, :s13, :string, :s14, :string, :s15, :string
    end

    class Gme
      class Error < StandardError; end
      OpenEmu = Data.define(:pointer, :m3u_loaded, :m3u_duration_entries)
      private_constant :OpenEmu

      def name = 'gme'

      def track_count(path)
        with_emu(path, GmeLib::GME_INFO_ONLY) { |emu| GmeLib.gme_track_count(emu) }
      end

      def metadata(path, subtune_index)
        with_emu(path, GmeLib::GME_INFO_ONLY, inspect_m3u_duration: true) do |emu, m3u_loaded, m3u_duration_entries|
          metadata_for(
            emu, path, subtune_index, ChiptuneMetadata.read(path),
            m3u_loaded: m3u_loaded, m3u_duration: m3u_duration_entries&.at(subtune_index)
          )
        end
      end

      # Each enumeration owns its handle, so extractor workers never share it.
      def each_metadata(path)
        return enum_for(__method__, path) unless block_given?

        with_emu(path, GmeLib::GME_INFO_ONLY, inspect_m3u_duration: true) do |emu, m3u_loaded, m3u_duration_entries|
          count = GmeLib.gme_track_count(emu)
          hardware = ChiptuneMetadata.read(path)
          count.times do |i|
            meta = metadata_for(
              emu, path, i, hardware,
              m3u_loaded: m3u_loaded, m3u_duration: m3u_duration_entries&.at(i)
            )
            yield meta, i, count
          end
        end
      end

      # Lengths Handle#initialize derives from gme_track_info, for backends
      # (SnesSpc) that decode elsewhere but must end tracks the same way.
      def playback_lengths(path, subtune_index)
        with_emu(path, GmeLib::GME_INFO_ONLY) do |emu|
          with_info(emu, subtune_index) do |info|
            { duration_ms: real_length(info), play_length_ms: info[:play_length] }
          end
        end
      end

      def open(path, subtune_index, sample_rate:)
        opened = open_emu(path, sample_rate)
        emu = opened.pointer
        # VGM command time includes leading silence. Keeping it prevents the
        # decoder and register telemetry from developing different time bases.
        # The same libgme switch also disables silence-based end-of-track
        # detection; that is intended, since VGM tracks end on their own end
        # command or the header length and fade.
        GmeLib.gme_ignore_silence(emu, 1) if Vgm::Reader.vgm_stream?(path)
        err = GmeLib.gme_start_track(emu, subtune_index)
        if err
          GmeLib.gme_delete(emu)
          raise Error, err
        end
        Handle.new(emu, subtune_index)
      end

      class Handle
        attr_reader :duration_ms, :mute_mask

        def initialize(emu, subtune_index)
          @emu = emu
          @mute_mask = 0
          info_ptr = FFI::MemoryPointer.new(:pointer)
          return unless GmeLib.gme_track_info(@emu, info_ptr, subtune_index).nil?

          info = GmeInfo.new(info_ptr.read_pointer)
          # info[:length] (see Gme#real_length) is the true reported duration.
          # play_length is only a fade target for tracks that loop forever --
          # it defaults to a flat 150000ms (2:30) when nothing else is known,
          # which is not a real duration and must never be shown as one.
          @duration_ms = info[:length] >= 0 ? info[:length] : nil
          play_len = info[:play_length]
          GmeLib.gme_set_fade(@emu, play_len) if play_len.positive?
          GmeLib.gme_free_info(info_ptr.read_pointer)
        end

        # Returns packed float32 stereo, or nil once the track has ended.
        def read(frames)
          return nil if @emu.nil? || GmeLib.gme_track_ended(@emu) != 0

          samples = frames * AudioFormat::CHANNELS
          if @buf.nil? || @buf_samples != samples
            @buf = FFI::MemoryPointer.new(:short, samples)
            @buf_samples = samples
          end
          err = GmeLib.gme_play(@emu, samples, @buf)
          raise Error, err if err

          @buf.read_bytes(samples * 2).unpack('s<*').map do |s|
            s / AudioFormat::GME_INT16_SCALE
          end.pack('e*')
        end

        def seek(ms)
          return false if @emu.nil?

          GmeLib.gme_seek(@emu, ms).nil?
        end

        def position_ms
          return 0 if @emu.nil?

          GmeLib.gme_tell(@emu)
        end

        # libgme voice bits; for VGM: FM 1-6, PCM (DAC), then all PSG channels.
        #
        # libgme's silence detection would hear a user mute and end the track,
        # and it cannot be re-armed safely: its silence clock stops while
        # ignoring silence, so turning detection back on during a quiet
        # passage ends the track at once. So the first mute turns it off for
        # the rest of the track. Tracks still end at their length or fade.
        def mute(mask)
          return if @emu.nil?

          @mute_mask = mask
          GmeLib.gme_ignore_silence(@emu, 1) unless mask.zero?
          GmeLib.gme_mute_voices(@emu, mask)
        end

        def close
          GmeLib.gme_delete(@emu) if @emu
          @emu = nil
        end
      end

      private

      def metadata_for(emu, path, subtune_index, hardware, m3u_loaded:, m3u_duration:)
        with_info(emu, subtune_index) do |info|
          {
            title: MetadataHelper.presence(info[:song]) || format('Track %02d', subtune_index + 1),
            album: MetadataHelper.presence(info[:game]),
            artist: MetadataHelper.presence(info[:author]),
            composer: MetadataHelper.presence(info[:author]),
            track_number: subtune_index + 1,
            **duration_metadata(info, m3u_loaded: m3u_loaded,
                                      m3u_duration: m3u_duration),
            format: MetadataHelper.format_extension(path),
            extra: hardware.merge(info_extras(info))
          }
        end
      end

      def info_extras(info)
        extras = %i[system copyright dumper comment].to_h do |field|
          [field.to_s, MetadataHelper.presence(info[field])]
        end
        %i[intro_length loop_length].each do |field|
          extras["#{field}_ms"] = info[field].to_s if info[field].positive?
        end
        extras.compact
      end

      def open_emu(path, sample_rate, inspect_m3u_duration: false)
        out = FFI::MemoryPointer.new(:pointer)
        err = GmeLib.gme_open_file(path, out, sample_rate)
        raise Error, err if err

        emu = out.read_pointer
        m3u_duration_entries = m3u_duration_entries(path) if inspect_m3u_duration
        m3u_loaded = load_sibling_m3u(emu, path)
        m3u_duration_entries = nil unless m3u_loaded
        OpenEmu.new(emu, m3u_loaded, m3u_duration_entries)
      end

      # NSF/HES-family rips rarely embed real per-track lengths themselves;
      # an m3u playlist with the same basename is the genre's convention for
      # supplying them (see fixtures/hes/air-zonk.{hes,m3u}). Best-effort: a
      # missing or malformed m3u just leaves GME's defaults in place rather
      # than failing the whole open.
      def load_sibling_m3u(emu, path)
        m3u_path = "#{path.sub(/\.[^.]+\z/, '')}.m3u"
        return false unless File.exist?(m3u_path)

        GmeLib.gme_load_m3u(emu, m3u_path).nil?
      end

      # libgme exposes the effective duration but not whether an individual
      # playlist entry supplied it. Parse only enough of its M3U grammar to
      # identify the length field; nil entries are ignored conservatively.
      def m3u_duration_entries(path)
        m3u_path = "#{path.sub(/\.[^.]+\z/, '')}.m3u"
        return unless File.file?(m3u_path)

        File.binread(m3u_path).lines(chomp: true).each_with_object([]) do |line, entries|
          next if line.empty? || line.start_with?('#')

          duration = m3u_entry_duration(line)
          entries << duration unless duration.nil?
        end
      rescue SystemCallError
        nil
      end

      def m3u_entry_duration(line)
        fields = m3u_fields_after_filename(line)
        return false unless fields

        track = fields.match(/\A(?:\$[0-9a-f]+|\d*)\s*,\s*/i)
        return unless track

        m3u_name_has_duration?(fields.byteslice(track[0].bytesize..))
      end

      def m3u_name_has_duration?(name_and_timing)
        index = 0
        while index < name_and_timing.bytesize
          byte = name_and_timing.getbyte(index)
          if byte == 92 # escaped character
            index += 2
            next
          end
          if byte == 44 # comma
            timing = name_and_timing.byteslice((index + 1)..).lstrip
            first = timing.getbyte(0)
            return digit_byte?(first) if first == 44 || first == 45 || digit_byte?(first)
          end
          index += 1
        end
        false
      end

      def m3u_fields_after_filename(line)
        index = 0
        while index < line.bytesize
          byte = line.getbyte(index)
          if byte == 92 # escaped character
            index += 2
            next
          end
          if line.byteslice(index, 2) == '::'
            comma = line.index(',', index + 2)
            return line.byteslice((comma + 1)..).lstrip if comma && comma > index + 3
          elsif byte == 44
            fields = line.byteslice((index + 1)..).lstrip
            first = fields.getbyte(0)
            return fields if first == 36 || digit_byte?(first)
          end
          index += 1
        end
        nil
      end

      def digit_byte?(byte) = byte&.between?(48, 57)

      def duration_metadata(info, m3u_loaded:, m3u_duration:)
        duration_ms = real_length(info)
        source = if duration_ms
                   m3u_loaded && m3u_duration ? 'm3u' : 'file'
                 elsif info[:loop_length].positive?
                   'loop_policy'
                 else
                   'default'
                 end
        {
          duration_ms: duration_ms,
          play_length_ms: (info[:play_length] if info[:play_length].positive?),
          duration_source: source
        }
      end

      # info[:length] is the file's (or a loaded m3u's) actual reported
      # duration, -1 if neither specifies one -- unlike info[:play_length],
      # it's never a fabricated default (see Handle#initialize).
      def real_length(info)
        info[:length] >= 0 ? info[:length] : nil
      end

      def with_emu(path, sample_rate, inspect_m3u_duration: false)
        opened = open_emu(path, sample_rate, inspect_m3u_duration: inspect_m3u_duration)
        yield opened.pointer, opened.m3u_loaded, opened.m3u_duration_entries
      ensure
        GmeLib.gme_delete(opened.pointer) if opened
      end

      def with_info(emu, subtune_index)
        info_ptr = FFI::MemoryPointer.new(:pointer)
        err = GmeLib.gme_track_info(emu, info_ptr, subtune_index)
        raise Error, err if err

        begin
          yield GmeInfo.new(info_ptr.read_pointer)
        ensure
          GmeLib.gme_free_info(info_ptr.read_pointer)
        end
      end
    end
  end
end
