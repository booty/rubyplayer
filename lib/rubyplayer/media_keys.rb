# frozen_string_literal: true

require 'ffi'

module RubyPlayer
  # Remote commands arrive on a native callback thread. The EventBus moves
  # them to the UI thread, where the same dispatch path handles keyboard input.
  class MediaKeys
    # C entry points for macOS's MediaPlayer remote command center.
    module Native
      extend FFI::Library

      ffi_lib File.expand_path('native/librp_media_keys.dylib', __dir__)
      callback :command_callback, [:int], :void
      attach_function :rp_media_keys_start, [:command_callback], :void
      attach_function :rp_media_keys_update, %i[string string string double double int], :void
      attach_function :rp_media_keys_stop, [], :void
    end

    COMMANDS = { 1 => :toggle_play, 2 => :next_track, 3 => :previous_track,
                 4 => :play, 5 => :pause }.freeze

    def initialize(event_bus:)
      @event_bus = event_bus
      @callback = proc do |command|
        action = COMMANDS[command]
        @event_bus.publish(:media_command, action: action) if action
      end
    end

    def start
      Native.rp_media_keys_start(@callback)
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
      Native.rp_media_keys_update(track&.title, track&.artist, track&.album,
                                  (track&.display_duration_ms || 0) / 1000.0,
                                  state[:position_ms] / 1000.0, playback_state)
    end

    def stop
      Native.rp_media_keys_stop
    end
  end
end
