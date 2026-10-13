# frozen_string_literal: true

require_relative '../hes/snapshot'
require_relative 'native_gme'

module RubyPlayer
  module Backends
    # Plays .hes through librp_hes: libgme's own HES emulator, vendored with
    # hooks that record HuC6280 PSG state for the live page.
    class HesNative < NativeGme
      class Error < StandardError; end

      # HuCard rips are at most a few hundred KB; the format addresses 1 MB.
      def self.native
        @native ||= Native.new(lib_file: 'hes_native_lib', lib: :HesNativeLib, prefix: 'rp_hes',
                               snapshot_type: Hes::Snapshot, label: 'HES', max_bytes: 4 * 1024 * 1024)
      end

      def name = 'hes_native'
    end
  end
end
