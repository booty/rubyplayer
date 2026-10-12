# frozen_string_literal: true

require 'stringio'
require 'zlib'

module RubyPlayer
  module Backends
    # libgme's gme_open_file transparently inflates gzip content under any
    # name (.spc, .gbs, ...); native players load bytes themselves, so they
    # must too, or such library entries scan fine and then fail to play.
    module GzipContent
      MAGIC = "\x1f\x8b".b

      # The file's bytes, inflated when gzip-compressed. Raises `error` when
      # the content (as stored or inflated) exceeds max_bytes, so a small
      # file cannot exhaust memory.
      def self.read(path, max_bytes:, error:, label:)
        bytes = File.binread(path)
        raise error, "#{label} file is too large" if bytes.bytesize > max_bytes
        return bytes unless bytes.start_with?(MAGIC)

        Zlib::GzipReader.wrap(StringIO.new(bytes)) do |gzip|
          inflated = gzip.read(max_bytes + 1) || ''.b
          raise error, "compressed #{label} is too large" if inflated.bytesize > max_bytes

          inflated
        end
      rescue Zlib::Error => e
        raise error, "invalid compressed #{label}: #{e.message}"
      end
    end
  end
end
