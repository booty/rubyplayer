# frozen_string_literal: true

require 'json'

module RubyPlayer
  # The bundled macOS helper owns the Now Playing app identity. Its stdout
  # commands enter EventBus so only the UI thread dispatches playback actions.
  class MediaKeys
    HELPER_PATH = File.expand_path('native/RubyPlayerMedia.app/Contents/MacOS/RubyPlayerMedia', __dir__)
    COMMANDS = { 1 => :toggle_play, 2 => :next_track, 3 => :previous_track,
                 4 => :play, 5 => :pause }.freeze

    def initialize(event_bus:)
      @event_bus = event_bus
    end

    def start
      @io = IO.popen([HELPER_PATH], 'r+')
      @reader_thread = Thread.new do
        @io.each_line do |line|
          action = COMMANDS[line.to_i]
          @event_bus.publish(:media_command, action: action) if action
        end
      end
    end

    def update(state)
      track = state[:track]
      playback_state = if state[:playing] && !state[:paused]
                         1
                       elsif state[:paused]
                         2
                       else
                         0
                       end
      payload = { title: track&.title, artist: track&.artist, album: track&.album,
                  duration_s: (track&.display_duration_ms || 0) / 1000.0,
                  position_s: state[:position_ms] / 1000.0, state: playback_state }
      return if payload == @last_payload

      @io.puts(JSON.generate(payload))
      @io.flush
      @last_payload = payload
    end

    def stop
      return unless @io

      @io.close_write
      @reader_thread.join(2)
      Process.kill('TERM', @io.pid) if @reader_thread.alive?
      @io.close
    end
  end
end
