# frozen_string_literal: true

require 'json'
require_relative 'native_paths'
require_relative 'playback_state'

module RubyPlayer
  # The bundled macOS helper owns the Now Playing app identity. Its stdout
  # commands enter EventBus so only the UI thread dispatches playback actions.
  class MediaKeys
    HELPER_PATH = NativePaths.absolute(NativePaths::MEDIA_KEYS_HELPER)
    # Line protocol, both directions by name so neither side depends on the
    # other's ordering. The helper writes one command name per line
    # (ext/rp_media_keys/rp_media_keys.m); unknown names are ignored.
    COMMANDS = %i[toggle_play next_track previous_track play pause].to_h { |action| [action.to_s, action] }.freeze
    PLAYING = 'playing'
    PAUSED = 'paused'
    STOPPED = 'stopped'
    # The helper is optional: losing its pipe must never take the player down.
    HELPER_GONE_ERRORS = [Errno::EPIPE, IOError].freeze
    # macOS advances elapsed time itself from the playback rate, so position
    # is resent only when it strays from that estimate: a seek, or drift.
    # Above the one-second publish cadence of engine positions.
    POSITION_DRIFT_TOLERANCE_S = 1.5
    MILLISECONDS_PER_SECOND = 1000.0

    def initialize(event_bus:, helper_launcher: -> { IO.popen([HELPER_PATH], 'r+') },
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @event_bus = event_bus
      @helper_launcher = helper_launcher
      @clock = clock
    end

    def start
      io = @io = @helper_launcher.call
      @reader_thread = Thread.new do
        io.each_line do |line|
          action = COMMANDS[line.strip]
          @event_bus.publish(:media_command, action: action) if action
        end
      rescue *HELPER_GONE_ERRORS
        nil
      end
    end

    def update(state)
      return unless @io

      track = state[:track]
      playback_state = if PlaybackState.actively_playing?(state)
                         PLAYING
                       elsif state[:paused]
                         PAUSED
                       else
                         STOPPED
                       end
      facts = { title: utf8(track&.title), artist: utf8(track&.artist), album: utf8(track&.album),
                duration_s: (track&.display_duration_ms || 0) / MILLISECONDS_PER_SECOND, state: playback_state }
      position_s = state[:position_ms] / MILLISECONDS_PER_SECOND
      return if facts == @sent_facts && (position_s - expected_position_s).abs <= POSITION_DRIFT_TOLERANCE_S

      @io.puts(JSON.generate(facts.merge(position_s: position_s)))
      @io.flush
      @sent_facts = facts
      @sent_position_s = position_s
      @sent_at_s = @clock.call
    rescue *HELPER_GONE_ERRORS
      stop
    end

    def stop
      io = @io
      return unless io

      @io = nil
      begin
        io.close_write
      rescue *HELPER_GONE_ERRORS
        nil
      end
      @reader_thread.join(2)
      Process.kill('TERM', io.pid) if @reader_thread.alive? && io.pid
      io.close
    rescue *HELPER_GONE_ERRORS, Errno::ESRCH
      nil
    end

    private

    # Where macOS now shows the playhead: the last sent position, advanced
    # in real time only while the helper was told playback is running.
    def expected_position_s
      return @sent_position_s unless @sent_facts[:state] == PLAYING

      @sent_position_s + (@clock.call - @sent_at_s)
    end

    # JSON.generate raises on invalid UTF-8, and tags read from files can
    # carry stray bytes. Binary strings are assumed to be mislabeled UTF-8.
    def utf8(text)
      return nil if text.nil?

      text = text.to_s
      text = text.dup.force_encoding(Encoding::UTF_8) if text.encoding == Encoding::BINARY
      text.encoding == Encoding::UTF_8 ? text.scrub : text.encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
    end
  end
end
