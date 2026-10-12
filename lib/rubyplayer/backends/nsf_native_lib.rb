# frozen_string_literal: true

require 'ffi'

module RubyPlayer
  module Backends
    # Binding for librp_nsf (ext/rp_nsf). Kept in its own file so requiring it
    # is the availability probe: a missing dylib raises LoadError here and
    # NsfNative falls back to libgme instead of failing at startup.
    module NsfNativeLib
      extend FFI::Library

      ffi_lib File.expand_path('../native/librp_nsf.dylib', __dir__)

      attach_function :rp_nsf_open, %i[pointer long int], :pointer
      attach_function :rp_nsf_close, [:pointer], :void
      attach_function :rp_nsf_load_m3u, %i[pointer pointer long], :int
      attach_function :rp_nsf_start_track, %i[pointer int], :int, blocking: true
      attach_function :rp_nsf_set_fade, %i[pointer long], :void
      attach_function :rp_nsf_ignore_silence, %i[pointer int], :void
      # Emulation runs in C; release the GVL like gme_play so the UI stays live.
      attach_function :rp_nsf_play, %i[pointer pointer long], :int, blocking: true
      attach_function :rp_nsf_track_ended, [:pointer], :int
      attach_function :rp_nsf_seek, %i[pointer long], :int, blocking: true
      attach_function :rp_nsf_tell_ms, [:pointer], :long
      attach_function :rp_nsf_mute_voices, %i[pointer int], :void
      attach_function :rp_nsf_voice_count, [:pointer], :int
      attach_function :rp_nsf_snapshot_size, [], :int
      attach_function :rp_nsf_snapshot_count, [:pointer], :int
      attach_function :rp_nsf_snapshots, [:pointer], :pointer
      attach_function :rp_nsf_capture_now, [:pointer], :void
    end
  end
end
