# frozen_string_literal: true

require_relative '../spc/timeline'

module RubyPlayer
  class PlaybackEngine
    # Live S-DSP state for SPC handles that record snapshots: which snapshot
    # is being heard and the latest SPC RAM. Split out of
    # PlaybackEngine as one concern; it relies on the engine's @mutex,
    # @audio, @handle, @commands, and playback flags.
    module SpcState
      # S-DSP state at the frame the device is playing, for SPC handles that
      # record snapshots; nil otherwise.
      def spc_live
        live, paused, mute_mask = @mutex.synchronize { [@playing && @spc_live && !@focus_sound, @paused, @voice_mute_mask] }
        return unless live

        Spc::LiveState.new(snapshot: @spc_timeline.at(@audio.frames_played), ram: @spc_ram, paused: paused,
                           mute_mask: mute_mask)
      end

      private

      # Snapshots wait with their chunk until its first write, the moment its
      # output-timeline origin is known. RAM is copied once per chunk (64 KB).
      def capture_spc_state
        return unless @handle.respond_to?(:take_snapshots)

        @pending_snapshots = @handle.take_snapshots
        @spc_ram = @handle.copy_ram
      end

      # A paused engine decodes nothing, so record the post-seek state now; it
      # plays from the next output frame (the ring was just flushed).
      def capture_spc_state_after_seek
        return unless @handle.respond_to?(:capture_now)

        packed, count = @handle.capture_now
        @spc_timeline.push(packed, count, origin_frame: @audio.frames_played + @audio.buffered_frames)
        @spc_ram = @handle.copy_ram
      end

      # Runs on a chunk's first write, when its output-timeline origin is known.
      def push_pending_snapshots(start_frame)
        return unless @pending_snapshots

        packed, count = @pending_snapshots
        @spc_timeline.push(packed, count, origin_frame: start_frame)
        @pending_snapshots = nil
      end

      # Caller holds @mutex: live only if the handle records snapshots.
      def start_spc_tracking
        @spc_live = @handle.respond_to?(:take_snapshots)
      end

      # Discontinuities (seek, track change, stop) drop everything: the
      # timeline only appends, and flushed positions get reused.
      def reset_spc_state
        @pending_snapshots = nil
        @spc_timeline.reset
        @spc_ram = nil
      end
    end
  end
end
