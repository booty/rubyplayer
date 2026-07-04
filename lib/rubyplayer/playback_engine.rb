require "time"
require_relative "audio_output"
require_relative "level_tap"

module RubyPlayer
  # Owns the decoder thread, the authoritative PlayQueue, and the AudioOutput.
  # UI threads call the public methods (commands in); events go out through
  # event_bus.publish. The audio device is started once and runs for the life
  # of the engine; pause/underrun emit silence.
  class PlaybackEngine
    def initialize(queue:, registry:, audio:, library:, event_bus:, config:)
      @queue = queue
      @registry = registry
      @audio = audio
      @library = library
      @bus = event_bus
      @chunk_frames = config["audio", "decode_chunk_frames"]
      @history_min_pct = config["library", "history_min_percent"]
      @history_min_unknown_ms = config["library", "history_min_seconds_unknown"] * 1000
      @level_tap = LevelTap.new(bands: config["eq", "bands"],
                                sample_rate: audio.sample_rate)
      @commands = Thread::Queue.new
      @mutex = Mutex.new # guards @queue and playback state reads from UI thread
      @playing = false
      @paused = false
      @skip_disliked = false
      @current = nil
      @handle = nil
      @pending = nil
      @frames_base = 0
      @seek_offset_ms = 0
      @started_at = nil
      @queue.on_change { @bus.publish(:queue_changed, items: @queue.items) }
    end

    def start
      @audio.start
      @thread = Thread.new { run }
      @thread.name = "decoder"
    end

    def shutdown
      @commands << :stop
      @thread&.join(5)
    end

    # ---- UI-facing commands (any thread) ----

    def enqueue_now(tracks)
      @mutex.synchronize { @queue.enqueue_now(tracks, playing: @playing) }
      @commands << :play_head
    end

    def enqueue_front(tracks)
      @mutex.synchronize { @queue.enqueue_front(tracks, playing: @playing) }
    end

    def enqueue_end(tracks)
      @mutex.synchronize { @queue.enqueue_end(tracks) }
    end

    def remove_at(index)
      @mutex.synchronize do
        # index 0 while playing is the current track: removing it = skip
        if index.zero? && @playing
          @commands << :skip
          nil
        else
          @queue.remove_at(index)
        end
      end
    end

    def undo = @mutex.synchronize { @queue.undo }
    def redo = @mutex.synchronize { @queue.redo }

    def toggle_play
      if @playing
        @commands << :toggle_pause
      else
        @commands << :play_head # no-op in the loop if the queue is empty
      end
    end

    def skip = @commands << :skip
    def seek(ms) = @commands << [:seek, ms]

    def toggle_skip_disliked
      @skip_disliked = !@skip_disliked
    end

    def queue_items = @mutex.synchronize { @queue.items }
    def levels = @level_tap.levels

    def state
      @mutex.synchronize do
        { track: @current, playing: @playing, paused: @paused,
          position_ms: position_ms, skip_disliked: @skip_disliked }
      end
    end

    private

    def position_ms
      return 0 unless @playing
      played = @audio.frames_played - @frames_base
      @seek_offset_ms + (played * 1000 / @audio.sample_rate)
    end

    # ---- decoder thread ----

    def run
      loop do
        cmd = begin
          @commands.pop(timeout: @playing && !@paused ? 0 : 0.05)
        rescue ThreadError
          nil
        end
        case cmd
        when :stop then break
        when :play_head then play_head
        when :skip then finish_and_advance
        when :toggle_pause then toggle_pause
        when Array then handle_seek(cmd[1]) if cmd[0] == :seek
        end
        pump if @playing && !@paused
      end
      close_handle
    end

    def pump
      if @pending
        written = @audio.write(@pending)
        consumed = written * AudioOutput::BYTES_PER_FRAME
        @pending = consumed < @pending.bytesize ? @pending.byteslice(consumed..) : nil
        sleep 0.005 if @pending # buffer full: yield briefly, stay responsive
        return
      end
      data = @handle&.read(@chunk_frames)
      if data.nil?
        finish_and_advance
      else
        @level_tap.push(data)
        @pending = data
        @bus.publish(:position, position_ms: position_ms, track_id: @current&.id)
      end
    end

    def play_head
      target = @mutex.synchronize { @queue.first }
      return if target.nil?
      close_handle
      open_and_play(target)
    end

    def open_and_play(track)
      track = next_playable(track)
      if track.nil?
        stop_playback
        return
      end
      backend = @registry.backend_for(track.physical_path)
      @handle = backend.open(track.physical_path, track.subtune_index,
                             sample_rate: @audio.sample_rate)
      @audio.paused = true
      @audio.flush
      @audio.paused = false
      @mutex.synchronize do
        @current = track
        @playing = true
        @paused = false
        @frames_base = @audio.frames_played
        @seek_offset_ms = 0
        @started_at = Time.now.utc
      end
      @level_tap.reset
      @bus.publish(:track_started, track: track)
      @bus.publish(:playback_state, playing: true, paused: false)
    rescue StandardError => e
      @library.set_errored(track.id) if track&.id
      @bus.publish(:track_error, track: track, message: e.message)
      @mutex.synchronize { @queue.advance! }
      retry_next = @mutex.synchronize { @queue.first }
      retry_next ? open_and_play(retry_next) : stop_playback
    end

    # Applies the skip-rated-1 rule, advancing past disliked tracks.
    def next_playable(track)
      while track && @skip_disliked && @library.rating_of(track.id) == 1
        track = @mutex.synchronize { @queue.advance! }
      end
      track
    end

    def finish_and_advance
      record_history
      @bus.publish(:track_ended, track: @current) if @current
      nxt = @mutex.synchronize { @queue.advance! }
      close_handle
      nxt ? open_and_play(nxt) : stop_playback
    end

    def stop_playback
      close_handle
      @audio.paused = true
      @audio.flush
      @mutex.synchronize do
        @current = nil
        @playing = false
        @paused = false
      end
      @bus.publish(:playback_state, playing: false, paused: false)
    end

    def toggle_pause
      return unless @playing
      @mutex.synchronize { @paused = !@paused }
      @audio.paused = @paused
      @bus.publish(:playback_state, playing: true, paused: @paused)
    end

    def handle_seek(ms)
      return unless @playing && @handle
      @audio.paused = true
      @audio.flush
      @pending = nil
      if @handle.seek(ms)
        @mutex.synchronize do
          @seek_offset_ms = ms
          @frames_base = @audio.frames_played
        end
      end
      @audio.paused = @paused
    end

    def record_history
      track = @current
      return unless track
      played_ms = position_ms
      threshold = if track.duration_ms&.positive?
                    track.duration_ms * @history_min_pct / 100.0
                  else
                    @history_min_unknown_ms
                  end
      return if played_ms < threshold
      @library.record_history(track_id: track.id,
                              started_at: @started_at.iso8601,
                              ended_at: Time.now.utc.iso8601)
    end

    def close_handle
      @handle&.close
      @handle = nil
      @pending = nil
    end
  end
end
