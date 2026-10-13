# frozen_string_literal: true

module RubyPlayer
  module Backends
    # The C API every native libgme player exports under its own prefix
    # (ext/rp_gbs/rp_gbs.h is the reference). Each binding module calls
    # ffi_lib itself, so requiring its file stays the availability probe.
    module NativeGmeLib
      PLAYER_API = {
        open: [%i[pointer long int], :pointer],
        close: [[:pointer], :void],
        load_m3u: [%i[pointer pointer long], :int],
        start_track: [%i[pointer int], :int],
        set_fade: [%i[pointer long], :void],
        ignore_silence: [%i[pointer int], :void],
        play: [%i[pointer pointer long], :int],
        track_ended: [[:pointer], :int],
        seek: [%i[pointer long], :int],
        tell_ms: [[:pointer], :long],
        mute_voices: [%i[pointer int], :void],
        snapshot_size: [[], :int],
        snapshot_count: [[:pointer], :int],
        snapshots: [[:pointer], :pointer],
        capture_now: [[:pointer], :void]
      }.freeze
      # Emulation runs in C; release the GVL like gme_play so the UI stays live.
      EMULATING_FUNCTIONS = %i[start_track play seek].freeze

      def self.attach_player_api(library, prefix)
        PLAYER_API.each do |function, (parameters, result)|
          options = EMULATING_FUNCTIONS.include?(function) ? { blocking: true } : {}
          library.attach_function(:"#{prefix}_#{function}", parameters, result, **options)
        end
      end
    end
  end
end
