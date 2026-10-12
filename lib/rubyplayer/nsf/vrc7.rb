# frozen_string_literal: true

require_relative '../vgm/chips/ym2413'

module RubyPlayer
  module Nsf
    # Konami's VRC7: a cut-down YM2413 (six melodic channels, no rhythm) with
    # its own instrument ROM. Fed register writes rebuilt from snapshots, it
    # gives the NSF live page the OPLL channel model the VGM page draws.
    class Vrc7 < Vgm::Chips::Ym2413
      CLOCK_HZ = 3_579_545
      # The ROM's instruments as commonly named (Konami never published names).
      PROGRAM_NAMES = [nil, 'Bell', 'Guitar', 'Piano', 'Flute', 'Clarinet', 'Rattling Bell', 'Trumpet', 'Reed Organ',
                       'Soft Bell', 'Xylophone', 'Vibraphone', 'Brass', 'Bass Guitar', 'Synthesizer',
                       'Chorus'].freeze

      def self.key = 'vrc7'
      def self.chip_name = 'Konami VRC7'
      def self.channel_count = 6
      def self.program_names = PROGRAM_NAMES

      def initialize = super(clock_hz: CLOCK_HZ)
    end
  end
end
