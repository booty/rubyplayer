# frozen_string_literal: true

require_relative '../audio_format'
require_relative '../gbs/snapshot'
require_relative 'gme'
require_relative 'gzip_content'

module RubyPlayer
  module Backends
    # Plays .gbs through librp_gbs: libgme's own GBS emulator, vendored with
    # hooks that record Game Boy APU state for the live page. Scanning stays
    # on libgme, so tags, lengths, and hardware extras are unchanged; only
    # decoding moves.
    class GbsNative
      class Error < StandardError; end

      # A GBS is a header plus at most a few MB of ROM banks.
      MAX_GBS_BYTES = 16 * 1024 * 1024
      private_constant :MAX_GBS_BYTES

      def self.available?
        return @available unless @available.nil?

        @available = begin
          require_relative 'gbs_native_lib'
          true
        rescue LoadError
          false
        end
      end

      def initialize(gme: Gme.new)
        @gme = gme
      end

      def name = 'gbs_native'
      def track_count(path) = @gme.track_count(path)
      def metadata(path, subtune_index) = @gme.metadata(path, subtune_index)

      def each_metadata(path, &)
        return enum_for(__method__, path) unless block_given?

        @gme.each_metadata(path, &)
      end

      def open(path, subtune_index, sample_rate:)
        raise Error, 'native GBS player is unavailable' unless self.class.available?

        # Read first: an unplayable file should fail here, not in libgme.
        bytes = GzipContent.read(path, max_bytes: MAX_GBS_BYTES, error: Error, label: 'GBS')
        lengths = @gme.playback_lengths(path, subtune_index)
        Handle.new(bytes, m3u: sibling_m3u(path), subtune_index: subtune_index,
                          sample_rate: sample_rate, **lengths)
      end

      # Same contract as Gme::Handle: packed float32 stereo until the track ends.
      class Handle
        attr_reader :duration_ms, :mute_mask

        def initialize(bytes, m3u:, subtune_index:, sample_rate:, duration_ms:, play_length_ms:)
          # rp_gbs_open copies the file, so the buffer may be freed afterwards.
          @gbs = GbsNativeLib.rp_gbs_open(*buffer(bytes), sample_rate)
          raise Error, 'not a playable GBS file' if @gbs.null?

          # As Gme#open_emu: a sibling m3u remaps track numbers. Best-effort.
          GbsNativeLib.rp_gbs_load_m3u(@gbs, *buffer(m3u)) if m3u
          unless GbsNativeLib.rp_gbs_start_track(@gbs, subtune_index) == 1
            close
            raise Error, "cannot start GBS track #{subtune_index + 1}"
          end
          @duration_ms = duration_ms
          @mute_mask = 0
          # Mirrors Gme::Handle: fade at libgme's play_length (a real length
          # or its 2:30 default).
          GbsNativeLib.rp_gbs_set_fade(@gbs, play_length_ms) if play_length_ms.positive?
        end

        def read(frames)
          # rp_gbs_play always fills the buffer, zero-padding after the end,
          # so the end check must come first (as with gme_track_ended).
          return nil if @gbs.nil? || GbsNativeLib.rp_gbs_track_ended(@gbs) != 0

          bytes = frames * AudioFormat::BYTES_PER_FRAME
          @buf = FFI::MemoryPointer.new(:uchar, bytes) if @buf.nil? || @buf.size != bytes
          raise Error, 'GBS emulation failed' unless GbsNativeLib.rp_gbs_play(@gbs, @buf, frames) == 1

          @buf.read_bytes(bytes)
        end

        # The engine's backend contract has seek report success, as Gme::Handle does.
        # rubocop:disable Naming/PredicateMethod
        def seek(milliseconds)
          return false if @gbs.nil?

          GbsNativeLib.rp_gbs_seek(@gbs, milliseconds) == 1
        end
        # rubocop:enable Naming/PredicateMethod

        def position_ms
          return 0 if @gbs.nil?

          GbsNativeLib.rp_gbs_tell_ms(@gbs)
        end

        # Bit 0 square 1, 1 square 2, 2 wave, 3 noise. Like Gme::Handle#mute,
        # the first mute turns libgme's silence detection off for the rest of
        # the track: it would hear the mute as the music ending.
        def mute(mask)
          return if @gbs.nil?

          @mute_mask = mask
          GbsNativeLib.rp_gbs_ignore_silence(@gbs, 1) unless mask.zero?
          GbsNativeLib.rp_gbs_mute_voices(@gbs, mask)
        end

        # Decodes take_snapshots records.
        def snapshot_record = Gbs::Snapshot

        # APU snapshots from the latest read as [packed records, count];
        # decode with Gbs::Snapshot.unpack.
        def take_snapshots
          return ['', 0] if @gbs.nil?

          count = GbsNativeLib.rp_gbs_snapshot_count(@gbs)
          return ['', 0] if count.zero?

          [GbsNativeLib.rp_gbs_snapshots(@gbs).read_bytes(count * Gbs::Snapshot::SIZE), count]
        end

        # The state heard at the current position (frame 0), then any already
        # emulated beyond it, without emulating: for showing a seek's new
        # position before any audio is decoded.
        def capture_now
          return ['', 0] if @gbs.nil?

          GbsNativeLib.rp_gbs_capture_now(@gbs)
          take_snapshots
        end

        def close
          GbsNativeLib.rp_gbs_close(@gbs) if @gbs
          @gbs = nil
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
