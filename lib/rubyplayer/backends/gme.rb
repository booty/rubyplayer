require "ffi"
require_relative "../runtime_dependencies"

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
      attach_function :gme_open_file, [:string, :pointer, :int], :string, blocking: true
      attach_function :gme_track_count, [:pointer], :int
      attach_function :gme_start_track, [:pointer, :int], :string
      attach_function :gme_play, [:pointer, :int, :pointer], :string, blocking: true
      attach_function :gme_track_ended, [:pointer], :int
      attach_function :gme_seek, [:pointer, :int], :string, blocking: true
      attach_function :gme_tell, [:pointer], :int
      attach_function :gme_set_fade, [:pointer, :int], :void
      attach_function :gme_track_info, [:pointer, :pointer, :int], :string, blocking: true
      attach_function :gme_free_info, [:pointer], :void
      attach_function :gme_delete, [:pointer], :void
      attach_function :gme_load_m3u, [:pointer, :string], :string, blocking: true
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

      def name = "gme"

      def track_count(path)
        with_emu(path, GmeLib::GME_INFO_ONLY) { |emu| GmeLib.gme_track_count(emu) }
      end

      def metadata(path, subtune_index)
        with_emu(path, GmeLib::GME_INFO_ONLY) do |emu|
          with_info(emu, subtune_index) do |info|
            {
              title: presence(info[:song]) || format("Track %02d", subtune_index + 1),
              album: presence(info[:game]),
              artist: presence(info[:author]),
              composer: presence(info[:author]),
              track_number: subtune_index + 1,
              duration_ms: real_length(info),
              format: File.extname(path).delete_prefix(".").downcase,
            }
          end
        end
      end

      def open(path, subtune_index, sample_rate:)
        emu = open_emu(path, sample_rate)
        err = GmeLib.gme_start_track(emu, subtune_index)
        if err
          GmeLib.gme_delete(emu)
          raise Error, err
        end
        Handle.new(emu, subtune_index)
      end

      class Handle
        attr_reader :duration_ms

        def initialize(emu, subtune_index)
          @emu = emu
          info_ptr = FFI::MemoryPointer.new(:pointer)
          if GmeLib.gme_track_info(@emu, info_ptr, subtune_index).nil?
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
        end

        # Returns packed float32 stereo, or nil once the track has ended.
        def read(frames)
          return nil if @emu.nil? || GmeLib.gme_track_ended(@emu) != 0
          samples = frames * 2
          if @buf.nil? || @buf_samples != samples
            @buf = FFI::MemoryPointer.new(:short, samples)
            @buf_samples = samples
          end
          err = GmeLib.gme_play(@emu, samples, @buf)
          raise Error, err if err
          @buf.read_bytes(samples * 2).unpack("s<*").map { |s| s / 32_768.0 }.pack("e*")
        end

        def seek(ms)
          return false if @emu.nil?

          GmeLib.gme_seek(@emu, ms).nil?
        end

        def position_ms
          return 0 if @emu.nil?

          GmeLib.gme_tell(@emu)
        end

        def close
          GmeLib.gme_delete(@emu) if @emu
          @emu = nil
        end
      end

      private

      def open_emu(path, sample_rate)
        out = FFI::MemoryPointer.new(:pointer)
        err = GmeLib.gme_open_file(path, out, sample_rate)
        raise Error, err if err
        emu = out.read_pointer
        load_sibling_m3u(emu, path)
        emu
      end

      # NSF/HES-family rips rarely embed real per-track lengths themselves;
      # an m3u playlist with the same basename is the genre's convention for
      # supplying them (see fixtures/air-zonk.{hes,m3u}). Best-effort: a
      # missing or malformed m3u just leaves GME's defaults in place rather
      # than failing the whole open.
      def load_sibling_m3u(emu, path)
        m3u_path = "#{path.sub(/\.[^.]+\z/, '')}.m3u"
        GmeLib.gme_load_m3u(emu, m3u_path) if File.exist?(m3u_path)
      end

      # info[:length] is the file's (or a loaded m3u's) actual reported
      # duration, -1 if neither specifies one -- unlike info[:play_length],
      # it's never a fabricated default (see Handle#initialize).
      def real_length(info)
        info[:length] >= 0 ? info[:length] : nil
      end

      def with_emu(path, sample_rate)
        emu = open_emu(path, sample_rate)
        yield emu
      ensure
        GmeLib.gme_delete(emu) if emu
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

      def presence(str) = str.nil? || str.empty? ? nil : str
    end
  end
end
