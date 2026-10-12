# frozen_string_literal: true

require 'ffi'

module RubyPlayer
  module Backends
    # Binding for librp_spc (ext/rp_spc). Kept in its own file so requiring it
    # is the availability probe: a missing dylib raises LoadError here and
    # SnesSpc falls back to libgme instead of failing at startup.
    module SnesSpcLib
      extend FFI::Library

      ffi_lib File.expand_path('../native/librp_spc.dylib', __dir__)

      attach_function :rp_spc_open, %i[pointer long int], :pointer
      attach_function :rp_spc_close, [:pointer], :void
      attach_function :rp_spc_set_fade, %i[pointer long long], :void
      attach_function :rp_spc_set_ignore_silence, %i[pointer int], :void
      # Emulation runs in C; release the GVL like gme_play so the UI stays live.
      attach_function :rp_spc_play, %i[pointer pointer long], :long, blocking: true
      attach_function :rp_spc_track_ended, [:pointer], :int
      attach_function :rp_spc_seek, %i[pointer long], :int, blocking: true
      attach_function :rp_spc_tell_ms, [:pointer], :long
      attach_function :rp_spc_mute_voices, %i[pointer int], :void
      attach_function :rp_spc_pause_silence_detection, %i[pointer int], :void
      attach_function :rp_spc_snapshot_size, [], :int
      attach_function :rp_spc_snapshot_count, [:pointer], :int
      attach_function :rp_spc_snapshots, [:pointer], :pointer
      attach_function :rp_spc_copy_ram, %i[pointer pointer], :void
    end
  end
end
