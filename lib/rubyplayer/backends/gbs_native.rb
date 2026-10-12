# frozen_string_literal: true

require_relative '../gbs/snapshot'
require_relative 'native_gme'

module RubyPlayer
  module Backends
    # Plays .gbs through librp_gbs: libgme's own GBS emulator, vendored with
    # hooks that record Game Boy APU state for the live page.
    class GbsNative < NativeGme
      class Error < StandardError; end

      # A GBS is a header plus at most a few MB of ROM banks.
      def self.native
        @native ||= Native.new(lib_file: 'gbs_native_lib', lib: :GbsNativeLib, prefix: 'rp_gbs',
                               record: Gbs::Snapshot, label: 'GBS', max_bytes: 16 * 1024 * 1024)
      end

      def name = 'gbs_native'
    end
  end
end
