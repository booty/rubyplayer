# frozen_string_literal: true

require 'json'

module RubyPlayer
  # The bundled macOS helper owns the Now Playing app identity. Its stdout
  # commands enter EventBus so only the UI thread dispatches playback actions.
  class MediaKeys
    HELPER_PATH = File.expand_path('native/RubyPlayerMedia.app/Contents/MacOS/RubyPlayerMedia', __dir__)
    COMMANDS = { 1 => :toggle_play, 2 => :next_track, 3 => :previous_track,
                 4 => :play, 5 => :pause }.freeze
    # The helper is optional: losing its pipe must never take the player down.
    HELPER_GONE_ERRORS = [Errno::EPIPE, IOError].freeze

    def initialize(event_bus:, helper_launcher: -> { IO.popen([HELPER_PATH], 'r+') })
      @event_bus = event_bus
      @helper_launcher = helper_launcher
    end

    def start
      io = @io = @helper_launcher.call
      @reader_thread = Thread.new do
        io.each_line do |line|
          action = COMMANDS[line.to_i]
          @event_bus.publish(:media_command, action: action) if action
        end
      rescue *HELPER_GONE_ERRORS
        nil
      end
    end

    def update(state)
      return unless @io

      track = state[:track]
      playback_state = if state[:playing] && !state[:paused]
                         1
                       elsif state[:paused]
                         2
                       else
                         0
                       end
      payload = { title: utf8(track&.title), artist: utf8(track&.artist), album: utf8(track&.album),
                  duration_s: (track&.display_duration_ms || 0) / 1000.0,
                  position_s: state[:position_ms] / 1000.0, state: playback_state }
      return if payload == @last_payload

      @io.puts(JSON.generate(payload))
      @io.flush
      @last_payload = payload
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
