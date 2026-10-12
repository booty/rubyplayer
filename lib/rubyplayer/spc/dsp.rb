# frozen_string_literal: true

require_relative 'snapshot'

module RubyPlayer
  module Spc
    # Decodes S-DSP register bytes (128 Integers) into named values for display.
    module Dsp
      # FLG bits 4-0 select the noise generator rate.
      NOISE_HZ = [0, 16, 21, 25, 31, 42, 50, 63, 83, 100, 125, 167, 200, 250, 333, 400, 500,
                  667, 800, 1000, 1300, 1600, 2000, 2700, 3200, 4000, 5300, 6400, 8000, 10_700,
                  16_000, 32_000].freeze
      GAIN_MODES = %i[linear_decrease exp_decrease linear_increase bent_increase].freeze
      NATIVE_RATE = 32_000
      PITCH_UNITY = 0x1000 # pitch value that plays a sample at its native 32 kHz
      # Each EDL step is 16 ms of echo and 2 KB of buffer; EDL 0 still uses 4 bytes.
      ECHO_MS_PER_STEP = 16
      ECHO_BYTES_PER_STEP = 2048
      ECHO_MIN_BYTES = 4
      # Balance beyond this reads as left/right rather than center.
      PAN_THRESHOLD = 0.33

      module_function

      def voice(regs, index)
        voice_sound(regs, index * 0x10).merge(voice_flags(regs, index))
      end

      def voice_sound(regs, base)
        vol_l = signed(regs[base])
        vol_r = signed(regs[base + 1])
        pitch = regs[base + 2] | ((regs[base + 3] & 0x3f) << 8)
        {
          vol_l: vol_l, vol_r: vol_r, pan: pan(vol_l, vol_r), balance: balance(vol_l, vol_r),
          pitch: pitch, rate_hz: pitch * NATIVE_RATE.to_f / PITCH_UNITY,
          pitch_ratio: pitch.to_f / PITCH_UNITY, srcn: regs[base + 4],
          adsr: adsr(regs[base + 5], regs[base + 6]), gain: gain(regs[base + 7]),
          envx: regs[base + 8], outx: signed(regs[base + 9])
        }
      end

      # Per-voice bits of the global KON/EON/NON/PMON/ENDX masks.
      def voice_flags(regs, index)
        {
          kon: regs[0x4c][index] == 1, echo: regs[0x4d][index] == 1,
          noise: regs[0x3d][index] == 1,
          # Voice 0 has no previous voice to be modulated by; its PMON bit is unused.
          pmod: index.positive? && regs[0x2d][index] == 1,
          ended: regs[0x7c][index] == 1
        }
      end

      def global(regs)
        flg = regs[0x6c]
        mvol = [signed(regs[0x0c]), signed(regs[0x1c])]
        evol = [signed(regs[0x2c]), signed(regs[0x3c])]
        {
          mvol: mvol, evol: evol,
          mvol_inverted: inverted?(*mvol), evol_inverted: inverted?(*evol),
          # Bit 5 *disables* echo writes, so echo_write is its inverse.
          flg: { reset: flg[7] == 1, mute: flg[6] == 1, echo_write: flg[5].zero?,
                 noise_hz: NOISE_HZ.fetch(flg & 0x1f) },
          eon: regs[0x4d], non: regs[0x3d], pmon: regs[0x2d] & 0xfe,
          endx: regs[0x7c], kon: regs[0x4c], koff: regs[0x5c], dir: regs[0x5d]
        }.merge(echo(regs))
      end

      def echo(regs)
        edl = regs[0x7d] & 0x0f
        {
          efb: signed(regs[0x0d]), esa: regs[0x6d], edl: edl, delay_ms: edl * ECHO_MS_PER_STEP,
          echo_bytes: edl.zero? ? ECHO_MIN_BYTES : edl * ECHO_BYTES_PER_STEP,
          fir: Array.new(8) { |tap| signed(regs[(tap * 0x10) + 0x0f]) }
        }
      end

      def adsr(adsr1, adsr2)
        { enabled: adsr1[7] == 1, ar: adsr1 & 0x0f, dr: (adsr1 >> 4) & 0x07,
          sl: adsr2 >> 5, sr: adsr2 & 0x1f }
      end

      def gain(value)
        return { mode: :direct, value: value & 0x7f } if value[7].zero?

        { mode: GAIN_MODES.fetch((value >> 5) & 0x03), value: value & 0x1f }
      end

      # Opposite signs put the two channels out of phase ("surround").
      def pan(left, right)
        return :surround if inverted?(left, right)

        value = balance(left, right)
        return :left if value < -PAN_THRESHOLD
        return :right if value > PAN_THRESHOLD

        :center
      end

      def balance(left, right)
        total = left.abs + right.abs
        total.zero? ? 0.0 : (right.abs - left.abs).fdiv(total)
      end

      def inverted?(left, right) = (left * right).negative?
      def signed(byte) = byte >= 0x80 ? byte - 0x100 : byte
    end
  end
end
