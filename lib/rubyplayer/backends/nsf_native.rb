# frozen_string_literal: true

require_relative '../nsf/snapshot'
require_relative 'native_gme'

module RubyPlayer
  module Backends
    # Plays .nsf and .nsfe through librp_nsf: libgme's own NSF emulator,
    # vendored with hooks that record 2A03 and expansion chip state for the
    # live page.
    class NsfNative < NativeGme
      class Error < StandardError; end

      # NSF banking addresses at most 1 MB of ROM; NSFe adds small chunks.
      def self.native
        @native ||= Native.new(lib_file: 'nsf_native_lib', lib: :NsfNativeLib, prefix: 'rp_nsf',
                               record: Nsf::Snapshot, label: 'NSF', max_bytes: 4 * 1024 * 1024)
      end

      def name = 'nsf_native'
    end
  end
end
