# frozen_string_literal: true

module RubyPlayer
  module Vgm
    # Converts register frequencies to approximate pitch labels for channel rows.
    module Pitch
      VGM_RATE = 44_100.0
      NOTE_NAMES = %w[C C# D D# E F F# G G# A A# B].freeze

      def self.ym2612_hz(clock_hz:, fnum:, block:)
        return unless valid?(clock_hz) && fnum.is_a?(Integer) && fnum.positive? && block.is_a?(Integer)

        clock_hz * fnum * (2**block) / (144.0 * (2**20))
      end

      def self.psg_hz(clock_hz:, period:, zero_period: 1024)
        return unless valid?(clock_hz) && period.is_a?(Integer) && period >= 0
        return if period.zero? && zero_period.nil?

        effective_period = period.zero? ? zero_period : period
        clock_hz / (32.0 * effective_period)
      end

      def self.ym2413_hz(clock_hz:, fnum:, block:)
        return unless valid?(clock_hz) && fnum.is_a?(Integer) && fnum.positive? && block.is_a?(Integer)

        clock_hz * fnum * (2**block) / (72.0 * (2**19))
      end

      def self.note_and_cents(frequency_hz)
        return [nil, nil] unless valid?(frequency_hz)

        midi_float = 69 + (12 * Math.log2(frequency_hz / 440.0))
        midi = midi_float.round
        ["#{NOTE_NAMES[midi % 12]}#{(midi / 12) - 1}", ((midi_float - midi) * 100).round]
      rescue Math::DomainError
        [nil, nil]
      end

      def self.valid?(value)
        value.is_a?(Numeric) && value.positive? && value.finite?
      end
      private_class_method :valid?
    end
  end
end
