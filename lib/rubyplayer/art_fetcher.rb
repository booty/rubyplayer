# frozen_string_literal: true

module RubyPlayer
  # Resolves album art off the UI thread and returns it as :art_ready
  # events. Resolution can spawn ffmpeg (embedded art), so one worker runs
  # fetches one at a time and only the newest request waits behind the
  # current one: skipping quickly through tracks replaces the pending track
  # instead of starting an extraction per track whose art would be dropped.
  class ArtFetcher
    # Shutdown waits this long for an in-flight fetch before leaving the
    # worker to die with the process.
    STOP_TIMEOUT_SECONDS = 1

    # display_max_px is read per fetch so config hot-reload applies.
    def initialize(artwork:, event_bus:, display_max_px:)
      @artwork = artwork
      @event_bus = event_bus
      @display_max_px = display_max_px
      @mutex = Mutex.new
      @wakeup = ConditionVariable.new
      @pending = nil
      @stopping = false
      @worker = nil
    end

    def request(track)
      @mutex.synchronize do
        return if @stopping

        @pending = track
        @wakeup.signal
        # Started on first use so Apps that never show art add no thread.
        @worker ||= Thread.new { work }
      end
    end

    def stop
      worker = @mutex.synchronize do
        @stopping = true
        @wakeup.signal
        @worker
      end
      worker&.join(STOP_TIMEOUT_SECONDS)
    end

    private

    def work
      while (track = next_track)
        @event_bus.publish(:art_ready, track_id: track.id, **art_for(track))
      end
    end

    def next_track
      @mutex.synchronize do
        @wakeup.wait(@mutex) until @pending || @stopping
        return nil if @stopping

        @pending.tap { @pending = nil }
      end
    end

    # Accent and downscaling ride in the same worker, so the UI thread never
    # waits on ffmpeg. Only the capped display copy crosses to the UI. Each
    # step fails alone: unreadable art still yields no art, not a crash.
    def art_for(track)
      bytes = attempt { @artwork.for_track(track) }
      return { bytes: nil, accent: nil } unless bytes

      { bytes: attempt { @artwork.display_bytes(bytes, max_px: @display_max_px.call) },
        accent: attempt { @artwork.average_color(bytes) } }
    end

    def attempt
      yield
    rescue StandardError
      nil
    end
  end
end
