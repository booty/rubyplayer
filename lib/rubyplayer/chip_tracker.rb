# frozen_string_literal: true

require_relative 'vgm/snapshot'
require_relative 'vgm/note_log'
require_relative 'vgm/pitch'

module RubyPlayer
  # What the GBS and NSF trackers share: turning the stream of native chip
  # snapshots (Gbs::Snapshot, Nsf::Snapshot) from an engine ChipLiveState
  # into the view snapshot (Vgm::Snapshot) the live page draws, with note
  # history. A tracker must see every native snapshot in order: note starts
  # and stops come from consecutive states, and a note shorter than a render
  # would otherwise be lost.
  #
  # Three representations meet here: the live state the engine hands over,
  # the native snapshots inside it, and the view snapshot built from them.
  # Times are converted from output frames to the 44.1 kHz samples the live
  # page counts in.
  #
  # Subclasses implement ingest(native_snapshot, sample), which records note
  # transitions, and build_view_snapshot(native_snapshot); reset_format_state
  # clears their own state on a new generation.
  class ChipTracker
    attr_reader :snapshot, :now_sample

    def initialize
      reset(nil)
    end

    # Feeds an engine ChipLiveState. Returns whether the view snapshot
    # changed (a new native snapshot or a new generation).
    def update(live_state)
      @sample_rate = live_state.sample_rate
      changed = live_state.generation != @generation
      reset(live_state.generation) if changed
      @track_generation = live_state.track_generation
      @now_sample = to_sample(live_state.frame)
      live_state.snapshots.each do |native_snapshot|
        ingest(native_snapshot, to_sample(native_snapshot.frame))
        @playing = native_snapshot.playing
        @latest = native_snapshot
      end
      return changed unless live_state.snapshots.any? || (changed && @latest)

      @snapshot = build_view_snapshot(@latest)
      true
    end

    private

    def reset(generation)
      @generation = generation
      @latest = nil
      # Bit v: voice v was sounding in the previous native snapshot.
      @playing = 0
      @trigger_samples = {}
      @release_samples = {}
      @snapshot = nil
      @now_sample = 0
      reset_format_state
    end

    def reset_format_state; end

    def to_sample(frame) = frame * Vgm::SAMPLE_RATE / @sample_rate

    # Records `voice`'s transition into `native_snapshot` as history channel
    # `index` of `notes`: newly sounding or retriggered starts a note, still
    # sounding follows its pitch, and falling silent ends it. `unpitched`
    # names a start's sound when it has no pitch (NoteLog#on).
    def record_note(notes, index, voice, native_snapshot, sample, midi, unpitched: nil)
      was = @playing[voice] == 1
      now = native_snapshot.playing[voice] == 1
      if now && (native_snapshot.triggers[voice] == 1 || !was)
        @trigger_samples[voice] = sample
        notes.on(index, sample, midi, unpitched: unpitched)
      elsif now
        notes.note(index, sample, midi)
      elsif was
        @release_samples[voice] = sample
        notes.off(index, sample)
      end
    end

    # Stereo placement from whether a voice reaches each side.
    def pan_from(left:, right:)
      if left && right then :lr
      elsif left then :l
      elsif right then :r
      else :none
      end
    end

    # The view snapshot around `chips`, at `native_snapshot`'s time.
    def view_snapshot(native_snapshot, chips)
      Vgm::Snapshot.new(generation: @track_generation, revision: @generation, sample: to_sample(native_snapshot.frame),
                        status: :ready, message: nil, loop_count: 0, chips: chips, warnings: [])
    end
  end
end
