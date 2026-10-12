# frozen_string_literal: true

require 'time'
require_relative 'audio_output'
require_relative 'level_tap'
require_relative 'vgm/reader'
require_relative 'vgm/snapshot'
require_relative 'spc/timeline'
require_relative 'playback_engine/spc_state'
require_relative 'playback_engine/voice_muting'

module RubyPlayer
  # Owns the decoder thread, the authoritative PlayQueue, and the AudioOutput.
  # UI threads call the public methods (commands in); events go out through
  # event_bus.publish. The audio device is started once and runs for the life
  # of the engine; pause/underrun emit silence.
  class PlaybackEngine
    include SpcState
    include VoiceMuting

    THREAD_JOIN_TIMEOUT_SECONDS = 5
    ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS = 0
    BUFFER_FULL_POLL_INTERVAL_SECONDS = 0.005
    # A full ring waits until this share of it is free, then refills in one
    # burst. Decoding in small bursts as space trickles free cost about 3x
    # the CPU for libgme FM emulation: each burst ran cache-cold. Refilling
    # at 75% full still leaves most of the ring as underrun headroom.
    REFILL_RING_FRACTION = 0.25
    # Upper bound on one wait, so a stalled device or rate mismatch is
    # rechecked promptly. Commands still wake the decoder immediately.
    MAX_REFILL_WAIT_SECONDS = 0.1
    MILLISECONDS_PER_SECOND = 1000
    VGM_DECODER_CAPABILITIES = { sn76489: true, ym2612: true, ym2413: true }.freeze
    PREVIOUS_TRACK_THRESHOLD_MS = 3_000
    PREVIOUS_TRACK_LIMIT = 100
    private_constant :THREAD_JOIN_TIMEOUT_SECONDS, :ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS,
                     :BUFFER_FULL_POLL_INTERVAL_SECONDS, :REFILL_RING_FRACTION,
                     :MAX_REFILL_WAIT_SECONDS,
                     :MILLISECONDS_PER_SECOND,
                     :VGM_DECODER_CAPABILITIES, :PREVIOUS_TRACK_THRESHOLD_MS,
                     :PREVIOUS_TRACK_LIMIT

    def initialize(queue:, registry:, audio:, library:, event_bus:, config:, focus_player:,
                   archive_cache: nil)
      @queue = queue
      @registry = registry
      @archive_cache = archive_cache
      @audio = audio
      @focus_player = focus_player
      @focus_sound = nil
      @library = library
      @bus = event_bus
      @chunk_frames = config['audio', 'decode_chunk_frames']
      @history_min_pct = config['library', 'history_min_percent']
      @history_min_unknown_ms = config['library', 'history_min_seconds_unknown'] * MILLISECONDS_PER_SECOND
      build_played_audio_followers(config)
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
      @vgm_generation = 0
      @vgm_revision = 0
      @vgm_source = nil
      @spc_live = false
      initialize_voice_muting
      @published_second = nil
      # Decoder-owned navigation history includes short plays that do not
      # qualify for the library's persistent listening history.
      @previous_tracks = []
      @last_started_track = nil
      @queue.on_change { safe_publish(:queue_changed, items: @queue.items) }
    end

    def start
      @audio.start
      @thread = Thread.new { run }
      @thread.name = 'decoder'
    end

    def shutdown
      return unless @thread

      error = nil
      begin
        stop_focus
      rescue StandardError => e
        error = e
      ensure
        @commands << :stop
        @thread.join(THREAD_JOIN_TIMEOUT_SECONDS)
        @thread = nil
      end
      raise error if error
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
        # Process after a queued skip so the removed current track cannot be
        # added back to navigation history by the ensuing track transition.
        @commands << [:forget_previous, ids.dup]
      end
    end

    def undo = @mutex.synchronize { @queue.undo }
    def redo = @mutex.synchronize { @queue.redo }

    def toggle_play
      @commands << if @playing
                     :toggle_pause
                   else
                     :play_head # no-op in the loop if the queue is empty
                   end
    end

    def skip = @commands << :skip
    def previous = @commands << :previous

    # Focus playback needs a complete handoff, not merely a queued stop request:
    # both sources share AudioOutput, so Focus must not unpause/write before the
    # decoder has closed its handle, paused the device, and flushed old samples.
    # The reply queue is a one-shot barrier from the decoder thread back to the
    # caller; queue contents remain untouched.
    def stop
      completed = Thread::Queue.new
      @commands << [:stop_playback, completed]
      completed.pop
    end

    def seek(ms) = @commands << [:seek, ms]

    # Focus is a process-backed PCM source, but AudioOutput remains decoder-
    # thread-owned. Synchronous replies report spawn/teardown errors to UI only
    # after source switch and native pause/flush ordering has completed.
    def play_focus(sound) = synchronous_command(:play_focus, sound)
    def stop_focus = synchronous_command(:stop_focus)

    def toggle_skip_disliked
      @skip_disliked = !@skip_disliked
    end

    def queue_items = @mutex.synchronize { @queue.items }

    def upcoming_items
      @mutex.synchronize do
        items = @queue.items
        @playing ? items.drop(1) : items
      end
    end

    def levels = @level_tap.levels(at_frame: @audio.frames_played)

    def state
      @mutex.synchronize do
        # Focus suspends finite queue playback without consuming its head. For
        # UI purposes that head is therefore "next"; during normal playback
        # the head is current, so next is the following queue entry.
        next_track = @queue.at(@playing ? 1 : 0)
        { track: @current, playing: @playing, paused: @paused,
          position_ms: position_ms, skip_disliked: @skip_disliked,
          focus_sound: @focus_sound, next_track: next_track }
      end
    end

    # Uses the audio callback's consumed-source counter, never decoder read-ahead.
    def vgm_telemetry_request
      @mutex.synchronize do
        return unless @playing && @vgm_source && !@focus_sound

        consumed_frames = [@audio.frames_played - @frames_base, 0].max
        seek_samples = [@seek_offset_ms, 0].max * Vgm::SAMPLE_RATE / MILLISECONDS_PER_SECOND
        elapsed_samples = consumed_frames * Vgm::SAMPLE_RATE / @audio.sample_rate
        Vgm::Request.new(source: @vgm_source, revision: @vgm_revision,
                         sample: seek_samples + elapsed_samples, paused: @paused)
      end
    end

    private

    def position_ms
      return 0 unless @playing

      played = @audio.frames_played - @frames_base
      @seek_offset_ms + (played * MILLISECONDS_PER_SECOND / @audio.sample_rate)
    end

    # ---- decoder thread ----

    def run
      wait = ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS
      loop do
        # While playing, pump returns how long until it has work: 0 keeps
        # decoding ahead to fill the ring; a full ring waits for a refill
        # burst. Waiting in pop rather than sleep lets commands (seek, skip,
        # stop) interrupt the wait immediately.
        cmd = begin
          active = @focus_sound || (@playing && !@paused)
          # Idle and paused sources have no work until a command wakes them.
          @commands.pop(timeout: active ? wait : nil)
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
          when :previous then restart_or_previous
          when :toggle_pause then toggle_pause
          when Array then handle_request(cmd)
          end
          wait = @focus_sound || (@playing && !@paused) ? pump : ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS
        rescue StandardError => e
          wait = ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS
          # A backend can raise mid-decode (e.g. gme_play failing on a
          # corrupt-but-openable file). Without this, the exception would
          # kill the decoder thread and playback would be dead until the
          # process restarts. Treat it like an open failure: flag the
          # track, tell the UI, and move on -- the thread must run until
          # an explicit :stop.
          @focus_sound ? handle_focus_error : handle_decode_error(e)
        end
      end
      begin
        stop_focus_playback
      ensure
        close_handle
      end
    end

    def handle_request(cmd)
      case cmd[0]
      when :seek then handle_seek(cmd[1])
      when :voice_mute then apply_voice_mute(cmd[1], cmd[2])
      when :forget_previous
        @previous_tracks.reject! { |track| cmd[1].include?(track.id) }
        @last_started_track = nil if cmd[1].include?(@last_started_track&.id)
      when :stop_playback
        begin
          stop_playback
        ensure
          # Never strand a caller if stop cleanup raises; run's rescue
          # still handles that error after the barrier is released.
          cmd[1] << true
        end
      when :play_focus then complete_focus_command(cmd[2]) { start_focus(cmd[1]) }
      when :stop_focus then complete_focus_command(cmd[1]) { stop_focus_playback }
      end
    end

    # Recovery for any exception raised while a track is current (mid-decode
    # read failure, or an error surfacing from pause/seek/history/advance
    # while a track was loaded). The same path handles open failures below so
    # back-to-back bad tracks behave identically in either phase.
    def handle_decode_error(e)
      recover_from_track_error(@current, e)
    end

    def recover_from_track_error(track, error)
      close_handle
      # Reset before advancing so `state` never reports a track that's no
      # longer decoding as current/playing during the retry window.
      @mutex.synchronize do
        @current = nil
        @playing = false
      end
      @library.set_errored(track.id) if track&.id
      safe_publish(:track_error, track: track, message: error.message) if track
      nxt = @mutex.synchronize { @queue.advance! }
      nxt ? open_and_play(nxt) : stop_playback
    end

    def handle_focus_error
      # Focus has no finite Track to mark errored or advance from. Retire only
      # this source; queue head remains untouched for later normal playback.
      stop_focus_playback
    rescue StandardError
      nil
    end

    # Returns seconds until pump has more work; the run loop waits that long
    # unless a command arrives first.
    def pump
      return write_pending if @pending

      if @focus_sound
        data = @focus_player.read(@chunk_frames)
        if data.nil?
          stop_focus_playback
        elsif data.empty?
          # Nonblocking pipe has no bytes yet. Yield so SoX can run while command
          # queue remains responsive to replacement and shutdown requests.
          return BUFFER_FULL_POLL_INTERVAL_SECONDS
        else
          @pending = data
          @pending_levels = false
        end
        return ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS
      end
      data = @handle&.read(@chunk_frames)
      if data.nil?
        finish_and_advance
      else
        @pending = data
        @pending_levels = true
        capture_spc_state
        publish_position
      end
      ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS
    end

    # Fills the ring to the brim, then waits until a refill burst's worth is
    # free before writing again (hysteresis). Writing every poll, or as soon
    # as any space freed, copied the whole pending chunk across FFI 200x a
    # second and kept decode bursts small.
    def write_pending
      writable = @audio.writable_frames
      if @awaiting_refill
        needed = refill_frames(writable)
        return refill_wait(needed - writable) if writable < needed

        @awaiting_refill = false
      end

      # Output-timeline frame where this write will play. Reading the two
      # counters separately can skew by one device period; harmless for EQ.
      start_frame = @audio.frames_played + @audio.buffered_frames
      pending_frames = @pending.bytesize / AudioFormat::BYTES_PER_FRAME
      chunk = writable < pending_frames ? @pending.byteslice(0, writable * AudioFormat::BYTES_PER_FRAME) : @pending
      written = chunk.empty? ? 0 : @audio.write(chunk)
      consumed = written * AudioFormat::BYTES_PER_FRAME
      @level_tap.push(chunk.byteslice(0, consumed), start_frame: start_frame) if @pending_levels && written.positive?
      push_pending_snapshots(start_frame) if written.positive?
      @pending = consumed < @pending.bytesize ? @pending.byteslice(consumed..) : nil
      return ACTIVE_COMMAND_POLL_TIMEOUT_SECONDS unless @pending

      # A stale flag after a flush is harmless: the emptied ring passes the
      # refill check at once.
      @awaiting_refill = true
      writable = @audio.writable_frames
      refill_wait(refill_frames(writable) - writable)
    end

    # EQ levels and S-DSP snapshots follow played audio. The level tap keeps
    # what can still wait in the ring plus the chunk being written; the SPC
    # timeline prunes by played position instead, because silence lookahead
    # can tag snapshots seconds ahead.
    def build_played_audio_followers(config)
      ring_frames = config['audio', 'ring_buffer_ms'] * @audio.sample_rate / MILLISECONDS_PER_SECOND
      @level_tap = LevelTap.new(bands: config['eq', 'bands'], sample_rate: @audio.sample_rate,
                                retain_frames: ring_frames + (2 * @chunk_frames))
      @spc_timeline = Spc::Timeline.new
      @spc_ram = nil
      @pending_snapshots = nil
    end

    def refill_frames(writable)
      capacity = writable + @audio.buffered_frames
      [(capacity * REFILL_RING_FRACTION).to_i, 1].max
    end

    def refill_wait(missing_frames)
      seconds = missing_frames.to_f / @audio.sample_rate
      seconds.clamp(BUFFER_FULL_POLL_INTERVAL_SECONDS, MAX_REFILL_WAIT_SECONDS)
    end

    # The UI renders position as m:ss, so anything finer than the displayed
    # second is wake-up noise: every publish writes the EventBus self-pipe
    # and rouses the main loop's IO.select. Unthrottled, pump emitted one
    # event per decoded chunk (~10/s), defeating the idle loop's longer
    # sleeps. Publish only when the displayed second changes; the marker is
    # reset on track start and seek so those repaint immediately.
    def publish_position
      pos = position_ms
      second = pos / MILLISECONDS_PER_SECOND
      return if second == @published_second

      @published_second = second
      safe_publish(:position, position_ms: pos, track_id: @current&.id)
    end

    def playable_path(track)
      entry = track.archive_entry.to_s
      return track.physical_path if entry.empty? || @archive_cache.nil?

      @archive_cache.materialize(track.physical_path, entry)
    end

    def play_head
      stop_focus_playback
      target = @mutex.synchronize { @queue.first }
      return if target.nil?

      close_handle
      open_and_play(target)
    end

    def open_and_play(track, remember_previous: true)
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
      vgm = track.backend.to_s == 'gme' && Vgm::Reader.vgm_stream?(path)
      @audio.paused = true
      @audio.flush
      @audio.paused = false
      @mutex.synchronize do
        remember_previous_track if remember_previous
        # Unlike @current, this survives an empty queue or a failed open.
        @last_started_track = track
        @current = track
        @playing = true
        @paused = false
        @frames_base = @audio.frames_played
        @seek_offset_ms = 0
        @vgm_generation += 1
        @vgm_revision = 0
        @vgm_source = vgm ? build_vgm_source(track, path) : nil
        start_spc_tracking
        start_voice_muting
        @started_at = Time.now.utc
      end
      reset_played_audio_followers
      @published_second = nil
      safe_publish(:track_started, track: track)
      safe_publish(:playback_state, playing: true, paused: false)
    rescue StandardError => e
      recover_from_track_error(track, e)
    end

    # Caller holds @mutex.
    def remember_previous_track
      return unless @last_started_track

      @previous_tracks << @last_started_track
      @previous_tracks.shift if @previous_tracks.size > PREVIOUS_TRACK_LIMIT
    end

    def build_vgm_source(track, path)
      Vgm::Source.new(
        generation: @vgm_generation,
        track_identity: [track.id, track.physical_path, track.archive_entry.to_s,
                         track.subtune_index],
        path: path, format: File.extname(path).delete_prefix('.').downcase.to_sym,
        sample_rate: @audio.sample_rate,
        timeline_policy: :libgme_vgm_samples,
        decoder_capabilities: VGM_DECODER_CAPABILITIES
      )
    end

    # Applies the skip-rated-1 rule, advancing past disliked tracks.
    def next_playable(track)
      track = @mutex.synchronize { @queue.advance! } while track && @skip_disliked && @library.rating_of(track.id) == 1
      track
    end

    def finish_and_advance
      record_history
      safe_publish(:track_ended, track: @current) if @current
      nxt = @mutex.synchronize { @queue.advance! }
      close_handle
      nxt ? open_and_play(nxt) : stop_playback
    end

    def restart_or_previous
      return unless @playing && @current

      if position_ms >= PREVIOUS_TRACK_THRESHOLD_MS || @previous_tracks.empty?
        handle_seek(0)
        return
      end

      target = @previous_tracks.pop
      record_history
      safe_publish(:track_ended, track: @current)
      @mutex.synchronize { @queue.rewind!(target) }
      close_handle
      open_and_play(target, remember_previous: false)
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

    def start_focus(sound)
      # Reuse normal stop semantics so queue remains intact while decoder handle
      # and buffered track samples are retired before SoX becomes active.
      stop_focus_playback
      stop_playback
      @focus_player.play(sound, sample_rate: @audio.sample_rate)
      @mutex.synchronize { @focus_sound = sound }
      @audio.paused = false
      true
    end

    def stop_focus_playback
      return false unless @mutex.synchronize { @focus_sound }

      begin
        @focus_player.stop
      ensure
        @mutex.synchronize { @focus_sound = nil }
        @pending = nil
        @audio.paused = true
        @audio.flush
      end
      true
    end

    def synchronous_command(name, payload = nil)
      return false unless @thread&.alive?

      reply = Thread::Queue.new
      command = payload.nil? ? [name, reply] : [name, payload, reply]
      @commands << command
      result = reply.pop
      raise result if result.is_a?(Exception)

      result
    end

    def complete_focus_command(reply)
      reply << yield
    rescue StandardError => e
      reply << e
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
      reset_spc_state
      if @handle.seek(ms)
        @mutex.synchronize do
          @seek_offset_ms = ms
          @frames_base = @audio.frames_played
          @vgm_revision += 1 if @vgm_source
        end
        capture_spc_state_after_seek
        @published_second = nil
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
      @mutex.synchronize do
        @vgm_source = nil
        @vgm_revision = 0
        @spc_live = false
        stop_voice_muting
      end
      reset_spc_state
    end

    def reset_played_audio_followers
      @level_tap.reset
      reset_spc_state
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
