# frozen_string_literal: true

require 'ffi'

module RubyPlayer
  module Backends
    # Binding for librp_gbs (ext/rp_gbs). Kept in its own file so requiring it
    # is the availability probe: a missing dylib raises LoadError here and
    # GbsNative falls back to libgme instead of failing at startup.
    module GbsNativeLib
      extend FFI::Library

      ffi_lib File.expand_path('../native/librp_gbs.dylib', __dir__)

      attach_function :rp_gbs_open, %i[pointer long int], :pointer
      attach_function :rp_gbs_close, [:pointer], :void
      attach_function :rp_gbs_load_m3u, %i[pointer pointer long], :int
      attach_function :rp_gbs_start_track, %i[pointer int], :int, blocking: true
      attach_function :rp_gbs_set_fade, %i[pointer long], :void
      attach_function :rp_gbs_ignore_silence, %i[pointer int], :void
      # Emulation runs in C; release the GVL like gme_play so the UI stays live.
      attach_function :rp_gbs_play, %i[pointer pointer long], :int, blocking: true
      attach_function :rp_gbs_track_ended, [:pointer], :int
      attach_function :rp_gbs_seek, %i[pointer long], :int, blocking: true
      attach_function :rp_gbs_tell_ms, [:pointer], :long
      attach_function :rp_gbs_mute_voices, %i[pointer int], :void
      attach_function :rp_gbs_snapshot_size, [], :int
      attach_function :rp_gbs_snapshot_count, [:pointer], :int
      attach_function :rp_gbs_snapshots, [:pointer], :pointer
      attach_function :rp_gbs_capture_now, [:pointer], :void
    end
  end
end
