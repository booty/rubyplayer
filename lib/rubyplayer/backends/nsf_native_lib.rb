# frozen_string_literal: true

require 'ffi'
require_relative 'native_gme_lib'

module RubyPlayer
  module Backends
    # Binding for librp_nsf (ext/rp_nsf). Kept in its own file so requiring it
    # is the availability probe: a missing dylib raises LoadError here and
    # NsfNative falls back to libgme instead of failing at startup.
    module NsfNativeLib
      extend FFI::Library

      ffi_lib File.expand_path('../native/librp_nsf.dylib', __dir__)

      NativeGmeLib.attach_player_api(self, 'rp_nsf')
      # NSF's voice count depends on which expansion chips the file uses.
      attach_function :rp_nsf_voice_count, [:pointer], :int
    end
  end
end
