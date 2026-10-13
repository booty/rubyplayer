# frozen_string_literal: true

require_relative '../audio_format'
require_relative 'gme'
require_relative 'gzip_content'

module RubyPlayer
  module Backends
    # A native player built on a vendored libgme emulator with hooks that
    # record chip state for a live page (ext/rp_gme): librp_gbs, librp_nsf.
    # Scanning stays on libgme, so tags, lengths, and hardware extras are
    # unchanged; only decoding moves. Subclasses name their library through
    # `native`: its binding file, C prefix, snapshot type, and size limit.
    class NativeGme
      Native = Data.define(:lib_file, :lib, :prefix, :snapshot_type, :label, :max_bytes) do
        # The binding module, once its file has loaded.
        def binding = Backends.const_get(lib)

        def call(function, *) = binding.public_send(:"#{prefix}_#{function}", *)
      end

      def self.available?
        return @available unless @available.nil?

        @available = begin
          require_relative native.lib_file
          true
        rescue LoadError
          false
        end
      end

      def initialize(gme: Gme.new)
        @gme = gme
      end

      def track_count(path) = @gme.track_count(path)
      def metadata(path, subtune_index) = @gme.metadata(path, subtune_index)

      def each_metadata(path, &)
        return enum_for(__method__, path) unless block_given?

        @gme.each_metadata(path, &)
      end

      def open(path, subtune_index, sample_rate:)
        native = self.class.native
        error = self.class::Error
        raise error, "native #{native.label} player is unavailable" unless self.class.available?

        # Read first: an unplayable file should fail here, not in libgme.
        bytes = GzipContent.read(path, max_bytes: native.max_bytes, error: error, label: native.label)
        lengths = @gme.playback_lengths(path, subtune_index)
        Handle.new(native, error, bytes, m3u: sibling_m3u(path), subtune_index: subtune_index,
                                         sample_rate: sample_rate, **lengths)
      end

      # Same contract as Gme::Handle: packed float32 stereo until the track ends.
      class Handle
        attr_reader :duration_ms, :mute_mask

        def initialize(native, error, bytes, m3u:, subtune_index:, sample_rate:, duration_ms:, play_length_ms:)
          @native = native
          @error = error
          # The library copies the file, so the buffer may be freed afterwards.
          @emu = native.call(:open, *buffer(bytes), sample_rate)
          raise error, "not a playable #{native.label} file" if @emu.null?

          # As Gme#open_emu: a sibling m3u remaps track numbers. Best-effort.
          native.call(:load_m3u, @emu, *buffer(m3u)) if m3u
          unless native.call(:start_track, @emu, subtune_index) == 1
            close
            raise error, "cannot start #{native.label} track #{subtune_index + 1}"
          end
          @duration_ms = duration_ms
          @mute_mask = 0
          # Mirrors Gme::Handle: fade at libgme's play_length (a real length
          # or its 2:30 default).
          native.call(:set_fade, @emu, play_length_ms) if play_length_ms.positive?
        end

        def read(frames)
          # Play always fills the buffer, zero-padding after the end, so the
          # end check must come first (as with gme_track_ended).
          return nil if @emu.nil? || @native.call(:track_ended, @emu) != 0

          bytes = frames * AudioFormat::BYTES_PER_FRAME
          @buf = FFI::MemoryPointer.new(:uchar, bytes) if @buf.nil? || @buf.size != bytes
          raise @error, "#{@native.label} emulation failed" unless @native.call(:play, @emu, @buf, frames) == 1

          @buf.read_bytes(bytes)
        end

        # The engine's backend contract has seek report success, as Gme::Handle does.
        # rubocop:disable Naming/PredicateMethod
        def seek(milliseconds)
          return false if @emu.nil?

          @native.call(:seek, @emu, milliseconds) == 1
        end
        # rubocop:enable Naming/PredicateMethod

        def position_ms
          return 0 if @emu.nil?

          @native.call(:tell_ms, @emu)
        end

        # libgme voice bits. Like Gme::Handle#mute, the first mute turns
        # libgme's silence detection off for the rest of the track: it would
        # hear the mute as the music ending.
        def mute(mask)
          return if @emu.nil?

          @mute_mask = mask
          @native.call(:ignore_silence, @emu, 1) unless mask.zero?
          @native.call(:mute_voices, @emu, mask)
        end

        # Decodes take_snapshots records.
        def snapshot_type = @native.snapshot_type

        # Chip snapshots from the latest read as [packed records, count];
        # decode with snapshot_type.unpack.
        def take_snapshots
          return ['', 0] if @emu.nil?

          count = @native.call(:snapshot_count, @emu)
          return ['', 0] if count.zero?

          [@native.call(:snapshots, @emu).read_bytes(count * @native.snapshot_type::SIZE), count]
        end

        # The state heard at the current position (frame 0), then any already
        # emulated beyond it, without emulating: for showing a seek's new
        # position before any audio is decoded.
        def capture_now
          return ['', 0] if @emu.nil?

          @native.call(:capture_now, @emu)
          take_snapshots
        end

        def close
          @native.call(:close, @emu) if @emu
          @emu = nil
        end

        private

        def buffer(bytes)
          pointer = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
          pointer.put_bytes(0, bytes)
          [pointer, bytes.bytesize]
        end
      end

      private

      # Same lookup as Gme#load_sibling_m3u.
      def sibling_m3u(path)
        m3u_path = "#{path.sub(/\.[^.]+\z/, '')}.m3u"
        File.binread(m3u_path) if File.file?(m3u_path)
      end
    end
  end
end
