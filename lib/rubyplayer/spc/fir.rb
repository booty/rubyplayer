# frozen_string_literal: true

module RubyPlayer
  module Spc
    # Frequency response of the S-DSP's 8-tap echo FIR filter.
    module Fir
      NATIVE_SAMPLE_RATE_HZ = 32_000.0
      TAP_UNITY = 128.0 # a single tap of 128 passes the echo unchanged
      LOW_HZ = 50.0
      HIGH_HZ = 16_000.0
      MIN_DB = -24.0
      MAX_DB = 12.0
      KIND_POINTS = 24
      FLAT_RANGE_DB = 3.0 # a curve varying less than this is "flat"
      SLOPE_DB = 6.0      # one end must beat the other by this to count as a pass

      module_function

      # Gain in dB at `points` log-spaced frequencies from 50 Hz to 16 kHz.
      def response(taps, points:)
        Array.new(points) do |index|
          magnitude_db(taps, LOW_HZ * ((HIGH_HZ / LOW_HZ)**(index / (points - 1.0))))
        end
      end

      def kind(taps)
        curve = response(taps, points: KIND_POINTS)
        return 'flat' if curve.max - curve.min < FLAT_RANGE_DB

        quarter = KIND_POINTS / 4
        low_band_db = mean(curve.first(quarter))
        high_band_db = mean(curve.last(quarter))
        middle_band_db = mean(curve[quarter...-quarter])
        return 'low-pass' if low_band_db >= high_band_db + SLOPE_DB && low_band_db >= middle_band_db - 3
        return 'high-pass' if high_band_db >= low_band_db + SLOPE_DB && high_band_db >= middle_band_db - 3
        return 'band-pass' if middle_band_db >= low_band_db + SLOPE_DB && middle_band_db >= high_band_db + SLOPE_DB

        'shaped'
      end

      def magnitude_db(taps, frequency_hz)
        real = imaginary = 0.0
        taps.each_with_index do |tap, index|
          angle_radians = 2 * Math::PI * frequency_hz * index / NATIVE_SAMPLE_RATE_HZ
          real += tap * Math.cos(angle_radians)
          imaginary -= tap * Math.sin(angle_radians)
        end
        magnitude = Math.hypot(real, imaginary) / TAP_UNITY
        return MIN_DB if magnitude.zero?

        (20 * Math.log10(magnitude)).clamp(MIN_DB, MAX_DB)
      end

      def mean(values) = values.sum / values.size
    end
  end
end
