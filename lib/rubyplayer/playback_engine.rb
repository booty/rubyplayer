require "time"
require_relative "audio_output"
require_relative "level_tap"

module RubyPlayer
  # Owns the decoder thread, the authoritative PlayQueue, and the AudioOutput.
  # UI threads call the public methods (commands in); events go out through
  # event_bus.publish. The audio device is started once and runs for the life
  # of the engine; pause/underrun emit silence.
  class PlaybackEngine
    def initialize(queue:, registry:, audio:, library:, event_bus:, config:, archive_cache: nil)
      @queue = queue
      @registry = registry
      @archive_cache = archive_cache
      @audio = audio
      @library = library
      @bus = event_bus
      @chunk_frames = config["audio", "decode_chunk_frames"]
      @history_min_pct = config["library", "history_min_percent"]
      @history_min_unknown_ms = config["library", "history_min_seconds_unknown"] * 1000
      @level_tap = LevelTap.new(bands: config["eq", "bands"],
                                sample_rate: audio.sample_rate)
      @commands = Thread::Queue.new
      # Guards @queue and the @current/@playing/@paused/@frames_base/@seek_offset_ms/
      # @started_at fields the decoder thread writes and `state`/UI commands read.
      # toggle_play's @playing read and toggle_skip_disliked's @skip_disliked write
      # deliberately skip the lock: MRI's GVL makes a single ivar read/write atomic,
      # and the decoder thread re-checks @playing/@skip_disliked itself before
      # acting on a command, so a stale read here only risks one redundant/delayed
      # command, never corrupted state.
      @mutex = Mutex.new
      @playing = false
      @paused = false
      @skip_disliked = false
      @current = nil
      @handle = nil
      @pending = nil
      @frames_base = 0
      @seek_offset_ms = 0
      @started_at = nil
      @queue.on_change { safe_publish(:queue_changed, items: @queue.items) }
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

    # Cascades a library deletion into the queue. If the currently-playing
    # track is among `ids`, its removal must go through :skip (like
    # #remove_at's index-0 case) so the decoder thread's finish_and_advance
    # shifts it off the head cleanly, rather than yanking @queue.first out
    # from under a handle that's still open and playing.
    def remove_track_ids(ids)
      @mutex.synchronize do
        ids = Array(ids)
        if @playing && @current && ids.include?(@current.id)
          @commands << :skip
          @queue.remove_track_ids(ids - [@current.id])
        else
          @queue.remove_track_ids(ids)
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
    # Focus playback needs to silence the decoder without consuming or clearing
    # its queue. Like other engine controls, this is queued so only the decoder
    # thread mutates handles and playback state.
    def stop = @commands << :stop_playback
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
        # 0 timeout while playing lets this loop decode-ahead as fast as possible
        # to fill the ring buffer; once it's full, pump's sleep(0.005) below
        # throttles back to short-interval polling. Intentional decode-ahead, not
        # a busy-wait bug.
        cmd = begin
          @commands.pop(timeout: @playing && !@paused ? 0 : 0.05)
        rescue ThreadError
          nil
        end
        # :stop must break unconditionally, before the rescue below gets a
        # chance to run -- an intentional shutdown is not a decode error and
        # must never be swallowed/retried.
        break if cmd == :stop
        begin
          case cmd
          when :play_head then play_head
          when :skip then finish_and_advance
          when :stop_playback then stop_playback
          when :toggle_pause then toggle_pause
          when Array then handle_seek(cmd[1]) if cmd[0] == :seek
          end
          pump if @playing && !@paused
        rescue StandardError => e
          # A backend can raise mid-decode (e.g. gme_play failing on a
          # corrupt-but-openable file). Without this, the exception would
          # kill the decoder thread and playback would be dead until the
          # process restarts. Treat it like an open failure: flag the
          # track, tell the UI, and move on -- the thread must run until
          # an explicit :stop.
          handle_decode_error(e)
        end
      end
      close_handle
    end

    # Recovery for any exception raised while a track is current (mid-decode
    # read failure, or an error surfacing from pause/seek/history/advance
    # while a track was loaded). Mirrors open_and_play's rescue so a run of
    # back-to-back bad tracks behaves identically regardless of whether the
    # failure happened while opening or while already playing.
    def handle_decode_error(e)
      failing = @current
      close_handle
      # Reset before advancing so `state` never reports a track that's no
      # longer decoding as current/playing during the retry window.
      @mutex.synchronize { @current = nil; @playing = false }
      @library.set_errored(failing.id) if failing&.id
      safe_publish(:track_error, track: failing, message: e.message) if failing
      nxt = @mutex.synchronize { @queue.advance! }
      nxt ? open_and_play(nxt) : stop_playback
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
        safe_publish(:position, position_ms: position_ms, track_id: @current&.id)
      end
    end

    def playable_path(track)
      entry = track.archive_entry.to_s
      return track.physical_path if entry.empty? || @archive_cache.nil?
      @archive_cache.materialize(track.physical_path, entry)
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
      # Archived tracks resolve to their extracted cache file first: backends
      # can only read real files, and backend_for must see the entry's own
      # extension (.vgm), not the container's (.zip). materialize re-extracts
      # if the cache was cleaned; failure lands in this method's rescue like
      # any other unplayable track.
      path = playable_path(track)
      backend = @registry.backend_for(path)
      @handle = backend.open(path, track.subtune_index,
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
      safe_publish(:track_started, track: track)
      safe_publish(:playback_state, playing: true, paused: false)
    rescue StandardError => e
      # Reset first: while retrying past several consecutive bad tracks,
      # `state` must not keep reporting the previous (already-closed)
      # attempt as current/playing.
      @mutex.synchronize { @current = nil; @playing = false }
      @library.set_errored(track.id) if track&.id
      safe_publish(:track_error, track: track, message: e.message)
      nxt = @mutex.synchronize { @queue.advance! }
      nxt ? open_and_play(nxt) : stop_playback
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
      safe_publish(:track_ended, track: @current) if @current
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
      safe_publish(:playback_state, playing: false, paused: false)
    end

    def toggle_pause
      return unless @playing
      @mutex.synchronize { @paused = !@paused }
      @audio.paused = @paused
      safe_publish(:playback_state, playing: true, paused: @paused)
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

    # Publish calls happen from inside code that may already hold @mutex
    # (e.g. @queue.on_change fires during a @mutex.synchronize block). That's
    # only safe because EventBus#publish is non-blocking and never re-enters
    # the engine (no callback here calls back into a locking engine method).
    # Rescuing here additionally means a misbehaving -- or pathologically
    # reentrant -- bus can't take the decoder thread down; telemetry must
    # never break playback.
    def safe_publish(type, **payload)
      @bus.publish(type, **payload)
    rescue StandardError
      nil
    end
  end
end
