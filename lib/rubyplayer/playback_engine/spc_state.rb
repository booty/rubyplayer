# frozen_string_literal: true

require_relative '../spc/timeline'

module RubyPlayer
  class PlaybackEngine
    # Live S-DSP state for SPC handles that record snapshots: which snapshot
    # is being heard, the latest SPC RAM, and voice muting. Split out of
    # PlaybackEngine as one concern; it relies on the engine's @mutex,
    # @audio, @handle, @commands, and playback flags.
    module SpcState
      # S-DSP state at the frame the device is playing, for SPC handles that
      # record snapshots; nil otherwise.
      def spc_live
        live, paused, mute_mask = @mutex.synchronize { [@playing && @spc_live && !@focus_sound, @paused, @spc_mute_mask] }
        return unless live

        Spc::LiveState.new(snapshot: @spc_timeline.at(@audio.frames_played), ram: @spc_ram, paused: paused,
                           mute_mask: mute_mask)
      end

      # Records the request at once so the UI reflects it, but only the decoder
      # thread touches the native handle. Audible after decoded audio drains.
      def mute_spc_voices(mask)
        @mutex.synchronize { @spc_mute_mask = mask }
        @commands << [:spc_mute, mask]
      end

      private

      # Snapshots wait with their chunk until its first write, the moment its
      # output-timeline origin is known. RAM is copied once per chunk (64 KB).
      def capture_spc_state
        return unless @handle.respond_to?(:take_snapshots)

        @pending_snapshots = @handle.take_snapshots
        @spc_ram = @handle.copy_ram
      end

      # Runs on a chunk's first write, when its output-timeline origin is known.
      def push_pending_snapshots(start_frame)
        return unless @pending_snapshots

        packed, count = @pending_snapshots
        @spc_timeline.push(packed, count, origin_frame: start_frame)
        @pending_snapshots = nil
      end

      # Caller holds @mutex: a new track starts unmuted, live only if its
      # handle records snapshots.
      def start_spc_tracking
        @spc_live = @handle.respond_to?(:take_snapshots)
        @spc_mute_mask = 0
      end

      def reset_spc_state
        @pending_snapshots = nil
        @spc_timeline.reset
        @spc_ram = nil
      end
    end
  end
end
