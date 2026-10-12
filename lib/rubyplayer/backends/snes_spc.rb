# frozen_string_literal: true

require_relative '../audio_format'
require_relative 'gme'

module RubyPlayer
  module Backends
    # Plays .spc through librp_spc, a port of libgme's SPC player that also
    # exposes S-DSP state. Scanning stays on libgme, so tags, lengths, and
    # hardware extras are unchanged; only decoding moves.
    class SnesSpc
      class Error < StandardError; end

      # gme_set_fade's default fade length; Gme::Handle relies on it.
      FADE_MS = 8_000
      private_constant :FADE_MS

      def self.available?
        return @available unless @available.nil?

        @available = begin
          require_relative 'snes_spc_lib'
          true
        rescue LoadError
          false
        end
      end

      def initialize(gme: Gme.new)
        @gme = gme
      end

      def name = 'snes_spc'
      def track_count(path) = @gme.track_count(path)
      def metadata(path, subtune_index) = @gme.metadata(path, subtune_index)

      def each_metadata(path, &)
        return enum_for(__method__, path) unless block_given?

        @gme.each_metadata(path, &)
      end

      def open(path, subtune_index, sample_rate:)
        raise Error, 'native SPC player is unavailable' unless self.class.available?

        lengths = @gme.playback_lengths(path, subtune_index)
        Handle.new(File.binread(path), sample_rate: sample_rate, **lengths)
      end

      # Same contract as Gme::Handle: packed float32 stereo until the track ends.
      class Handle
        attr_reader :duration_ms

        def initialize(bytes, sample_rate:, duration_ms:, play_length_ms:)
          data = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
          data.put_bytes(0, bytes)
          # rp_spc_open copies the file, so `data` may be freed afterwards.
          @spc = SnesSpcLib.rp_spc_open(data, bytes.bytesize, sample_rate)
          raise Error, 'not a playable SPC file' if @spc.null?

          @duration_ms = duration_ms
          # Mirrors Gme::Handle: fade at libgme's play_length (a real length or
          # its 2:30 default) so looping SPCs end the same way on both backends.
          SnesSpcLib.rp_spc_set_fade(@spc, play_length_ms, FADE_MS) if play_length_ms.positive?
        end

        def read(frames)
          # rp_spc_play always fills the buffer, zero-padding after the end,
          # so the end check must come first (as with gme_track_ended).
          return nil if @spc.nil? || SnesSpcLib.rp_spc_track_ended(@spc) != 0

          bytes = frames * AudioFormat::BYTES_PER_FRAME
          @buf = FFI::MemoryPointer.new(:uchar, bytes) if @buf.nil? || @buf.size != bytes
          SnesSpcLib.rp_spc_play(@spc, @buf, frames)
          @buf.read_bytes(bytes)
        end

        # The engine's backend contract has seek report success, as Gme::Handle does.
        # rubocop:disable Naming/PredicateMethod
        def seek(milliseconds)
          return false if @spc.nil?

          SnesSpcLib.rp_spc_seek(@spc, milliseconds) == 1
        end
        # rubocop:enable Naming/PredicateMethod

        def position_ms
          return 0 if @spc.nil?

          SnesSpcLib.rp_spc_tell_ms(@spc)
        end

        def close
          SnesSpcLib.rp_spc_close(@spc) if @spc
          @spc = nil
        end
      end
    end
  end
end
