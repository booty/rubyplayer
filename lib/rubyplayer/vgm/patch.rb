# frozen_string_literal: true

require 'digest'
require_relative 'snapshot'

module RubyPlayer
  module Vgm
    # Builds stable content signatures from chip-specific timbre parameters.
    class Patch
      def self.from_bytes(chip:, bytes:, algorithm: nil, feedback: nil,
                          operators: [], details: {})
        canonical = bytes.is_a?(String) ? bytes.b : Array(bytes).pack('C*')
        new(digest: Digest::SHA256.hexdigest("#{chip}:".b + canonical),
            algorithm: algorithm, feedback: feedback, operators: operators,
            details: details.merge(chip: chip))
      end

      def short_digest = digest[0, 12]
    end
  end
end
