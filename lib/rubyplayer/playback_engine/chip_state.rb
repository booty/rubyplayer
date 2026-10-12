# frozen_string_literal: true

require_relative '../chip_timeline'
require_relative '../spc/snapshot'
require_relative '../gbs/snapshot'

module RubyPlayer
  class PlaybackEngine
    # Live chip state for handles that record native snapshots (SPC S-DSP,
    # GBS APU): which snapshot is being heard, plus SPC RAM. Split out of
    # PlaybackEngine as one concern; it relies on the engine's @mutex,
    # @audio, @handle, @commands, and playback flags.
    module ChipState
      # Keeps a long-closed live page from replaying minutes of snapshots on
      # reopen; the page's history only spans seconds.
      MAX_GBS_SNAPSHOTS_PER_CALL = 2_048

      # S-DSP state at the frame the device is playing, for SPC handles;
      # nil otherwise.
      def spc_live
        live, paused, mute_mask = live_flags(Spc::Snapshot)
        return unless live

        Spc::LiveState.new(snapshot: @chip_timeline.at(@audio.frames_played), ram: @spc_ram, paused: paused,
                           mute_mask: mute_mask)
      end

      # GBS APU snapshots heard since the previous call, for GBS handles; nil
      # otherwise. Consumes them: one caller (the live page) only.
      def gbs_live
        live, paused, mute_mask, generation, track_generation = live_flags(Gbs::Snapshot)
        return unless live

        frame = @audio.frames_played
        snapshots = @chip_timeline.take_through(frame, limit: MAX_GBS_SNAPSHOTS_PER_CALL)
        Gbs::LiveState.new(snapshots: snapshots, latest: snapshots.last, generation: generation,
                           track_generation: track_generation, frame: frame, sample_rate: @audio.sample_rate,
                           paused: paused, mute_mask: mute_mask)
      end

      # Which native live state the current track records (:spc, :gbs), or
      # nil. Unlike gbs_live it consumes nothing.
      def chip_live_kind
        kind = { Spc::Snapshot => :spc, Gbs::Snapshot => :gbs }.fetch(@chip_record, nil)
        live, = live_flags(@chip_record)
        kind if live
      end

      private

      def live_flags(record)
        @mutex.synchronize do
          live = @playing && @chip_record == record && !@focus_sound
          [live, @paused, @voice_mute_mask, @chip_generation, @vgm_generation]
        end
      end

      # Snapshots wait with their chunk until its first write, the moment its
      # output-timeline origin is known. SPC RAM is copied once per chunk
      # (64 KB).
      def capture_chip_state
        return unless @handle.respond_to?(:take_snapshots)

        @pending_snapshots = [*@handle.take_snapshots, @handle.snapshot_record]
        @spc_ram = @handle.copy_ram if @handle.respond_to?(:copy_ram)
      end

      # A paused engine decodes nothing, so record the post-seek state now; it
      # plays from the next output frame (the ring was just flushed).
      def capture_chip_state_after_seek
        return unless @handle.respond_to?(:capture_now)

        packed, count = @handle.capture_now
        @chip_timeline.push(packed, count, origin_frame: @audio.frames_played + @audio.buffered_frames,
                                           record: @handle.snapshot_record)
        @spc_ram = @handle.copy_ram if @handle.respond_to?(:copy_ram)
      end

      # Runs on a chunk's first write, when its output-timeline origin is known.
      def push_pending_snapshots(start_frame)
        return unless @pending_snapshots

        packed, count, record = @pending_snapshots
        @chip_timeline.push(packed, count, origin_frame: start_frame, record: record)
        @pending_snapshots = nil
      end

      # Caller holds @mutex: live only if the handle records snapshots.
      def start_chip_tracking
        @chip_record = (@handle.snapshot_record if @handle.respond_to?(:take_snapshots))
      end

      # Discontinuities (seek, track change, stop) drop everything: the
      # timeline only appends, and flushed positions get reused. The new
      # generation tells the GBS page to restart its note history.
      def reset_chip_state
        @pending_snapshots = nil
        @chip_timeline.reset
        @spc_ram = nil
        @mutex.synchronize { @chip_generation += 1 }
      end
    end
  end
end
