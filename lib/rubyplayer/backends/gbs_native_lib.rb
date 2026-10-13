# frozen_string_literal: true

require 'ffi'
require_relative 'native_gme_lib'

module RubyPlayer
  module Backends
    # Binding for librp_gbs (ext/rp_gbs). Kept in its own file so requiring it
    # is the availability probe: a missing dylib raises LoadError here and
    # GbsNative falls back to libgme instead of failing at startup.
    module GbsNativeLib
      extend FFI::Library

      ffi_lib File.expand_path('../native/librp_gbs.dylib', __dir__)

      NativeGmeLib.attach_player_api(self, 'rp_gbs')
    end
  end
end
