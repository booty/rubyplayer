# frozen_string_literal: true

module RubyPlayer
  class PlaybackEngine
    # User voice muting for handles that support it (native SPC, libgme).
    # Split out of PlaybackEngine as one concern; it relies on the engine's
    # @mutex, @handle, @commands, and @playing.
    module VoiceMuting
      # Records the request at once so the UI reflects it, but only the decoder
      # thread touches the native handle. Audible after decoded audio drains.
      # The command carries the track's generation: a track change queued
      # ahead of it must not inherit the mute. Returns whether it was queued.
      # rubocop:disable Naming/PredicateMethod
      def mute_voices(mask)
        @mutex.synchronize do
          return false unless @playing && @voice_muting_supported

          @voice_mute_mask = mask
          @commands << [:voice_mute, mask, @voice_generation]
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # The current track's mask, or nil when its handle cannot mute.
      def voice_mute_mask
        @mutex.synchronize { @voice_mute_mask if @playing && @voice_muting_supported }
      end

      private

      def initialize_voice_muting
        @voice_muting_supported = false
        @voice_mute_mask = 0
        @voice_generation = 0
      end

      # Caller holds @mutex: every track starts unmuted.
      def start_voice_muting
        @voice_muting_supported = @handle.respond_to?(:mute)
        @voice_mute_mask = 0
        @voice_generation += 1
      end

      # Caller holds @mutex.
      def stop_voice_muting
        @voice_muting_supported = false
      end

      # Decoder thread: apply a queued mute unless its track has been replaced.
      def apply_voice_mute(mask, generation)
        current = @mutex.synchronize { @voice_generation }
        @handle.mute(mask) if generation == current && @handle.respond_to?(:mute)
      end
    end
  end
end
