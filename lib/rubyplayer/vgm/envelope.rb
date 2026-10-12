# frozen_string_literal: true

require_relative 'snapshot'

module RubyPlayer
  module Vgm
    # Estimates envelope levels from register state and key timing. The replay
    # tracks registers, not the chip's internal envelope generator, so the
    # live page models it in closed form from the rates instead (after MAME's
    # fm.cpp / emu2413): exponential attack, linear-in-dB decay, sustain, and
    # release. Good enough to show a note's shape; not sample-accurate (SSG-EG,
    # LFO tremolo, and rate scaling edge cases are ignored).
    #
    # Levels are attenuations in 10-bit EG steps: 0 is full volume, 1023 is
    # silent, and each step is 96/1024 dB.
    module Envelope
      MAX_ATTENUATION = 1023
      DB_PER_STEP = 96.0 / 1024
      # OPN2 keycode from block and the top four F-number bits (MAME opn_fktable).
      OPN_FKTABLE = [0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3].freeze
      # Which operators reach the output, per YM2612 algorithm.
      CARRIERS = [[4], [4], [4], [4], [2, 4], [2, 3, 4], [2, 3, 4], [1, 2, 3, 4]].freeze
      # Average per-update increments for rates below 48 (MAME eg_inc rows),
      # indexed by rate % 4.
      LOW_RATE_INCREMENTS = [0.5, 0.625, 0.75, 0.875].freeze
      # The attack recurrence a -= (a + 1) * inc / 16 integrates to
      # a(t) + 1 = 1024 * exp(-inc_rate * t / 16).
      ATTACK_DIVISOR = 16.0
      INSTANT_ATTACK_RATE = 62
      # OPLL key-off with the sustain flag set releases at this fixed rate.
      OPLL_SUSTAIN_RELEASE = 5
      # ROM instruments have no readable rates: assume a quick fade on key-off.
      OPLL_ROM_RELEASE_SECONDS = 0.3

      module_function

      def to_db(attenuation) = -attenuation.clamp(0, MAX_ATTENUATION) * DB_PER_STEP

      def opn_keycode(fnum:, block:) = (block << 2) | OPN_FKTABLE.fetch((fnum >> 7) & 0x0f)

      # EG steps per second for an effective rate 0..63.
      def steps_per_second(rate, eg_hz)
        return 0.0 if rate < 2

        rate = rate.clamp(0, 63)
        per_update = if rate < 48
                       LOW_RATE_INCREMENTS[rate % 4] / (2**(11 - (rate / 4)))
                     elsif rate < 60
                       (2**((rate - 48) / 4)) * (1 + ((rate % 4) * 0.25))
                     else
                       8.0
                     end
        per_update * eg_hz
      end

      # One YM2612 operator's attenuation including its total level, or
      # MAX_ATTENUATION before any key-on. `held` and `released` are seconds
      # since key-on and key-off (released nil while the key is held).
      def opn_operator(parameters, keycode:, clock_hz:, held:, released: nil)
        total(opn_curve(parameters, keycode, clock_hz).at(held, released), parameters[:tl].to_i * 8)
      end

      def opn_curve(parameters, keycode, clock_hz)
        eg_hz = clock_hz / 144.0 / 3
        scale = keycode >> (3 - parameters.fetch(:rs, 0).to_i)
        rate = ->(value) { value.to_i.zero? ? 0 : ((2 * value.to_i) + scale).clamp(0, 63) }
        speed = ->(value) { steps_per_second(rate.call(value), eg_hz) }
        # Release has no zero rate: RR 0 is rate 2 plus key scaling, a slow
        # but finite fade (MAME fm.cpp sets rr = 34 + (RR << 2)).
        release_rate = ((4 * parameters[:rr].to_i) + 2 + scale).clamp(0, 63)
        Curve.new(attack: speed.call(parameters[:ar]), instant: rate.call(parameters[:ar]) >= INSTANT_ATTACK_RATE,
                  decay: speed.call(parameters[:d1r]), sustain_level: sustain_level(parameters[:d1l]),
                  sustain: speed.call(parameters[:d2r]), release: steps_per_second(release_rate, eg_hz))
      end

      # Loudest carrier of a YM2612 channel, as an attenuation. Each
      # operator has its own key, so `timings` holds [held, released] per
      # operator (index 1..4 at 0..3); held is nil for one never keyed.
      def opn_channel(patch, keycode:, clock_hz:, timings:)
        return MAX_ATTENUATION unless patch&.algorithm

        CARRIERS.fetch(patch.algorithm).map do |index|
          operator = patch.operators.find { |item| item.index == index }
          held, released = timings[index - 1]
          next MAX_ATTENUATION unless operator && held

          opn_operator(operator.parameters, keycode: keycode, clock_hz: clock_hz, held: held, released: released)
        end.min
      end

      # YM2413 carrier with readable (custom) rates. Percussive patches
      # (EG type 0) keep decaying at the release rate while held.
      def opll_custom(parameters, block:, clock_hz:, volume:, held:, released: nil, sustain_flag: false)
        curve = opll_curve(parameters, block, clock_hz, sustain_flag)
        total(curve.at(held, released), volume.to_i * 32)
      end

      def opll_curve(parameters, block, clock_hz, sustain_flag)
        eg_hz = clock_hz / 72.0
        scale = parameters[:ksr].to_i == 1 ? block * 2 : (block * 2) >> 2
        speed = ->(value) { steps_per_second(value.to_i.zero? ? 0 : ((4 * value.to_i) + scale).clamp(0, 63), eg_hz) }
        percussive = parameters[:eg].to_i.zero?
        Curve.new(attack: speed.call(parameters[:ar]), instant: parameters[:ar].to_i == 15,
                  decay: speed.call(parameters[:dr]), sustain_level: sustain_level(parameters[:sl]),
                  sustain: percussive ? speed.call(parameters[:rr]) : 0.0,
                  release: speed.call(sustain_flag ? OPLL_SUSTAIN_RELEASE : parameters[:rr]))
      end

      # ROM instruments: the volume register while held, then a short fade.
      def opll_rom(volume:, released: nil)
        base = volume.to_i * 32
        return total(0, base) unless released

        total((released / OPLL_ROM_RELEASE_SECONDS * MAX_ATTENUATION).round, base)
      end

      # SN76489 attenuation is direct: 2 dB per step, 15 is off.
      def psg(attenuation)
        return MAX_ATTENUATION if attenuation.nil? || attenuation >= 15

        (attenuation * 2 / DB_PER_STEP).round
      end

      # D1L/SL 15 means "all the way down" (-93 dB), not 15 * 3 dB.
      def sustain_level(value)
        value = value.to_i
        value >= 15 ? MAX_ATTENUATION : value * 32
      end

      def total(envelope, offset) = (envelope + offset).round.clamp(0, MAX_ATTENUATION)

      # Attack, decay to the sustain level, sustain slope, and release, each
      # in EG steps per second.
      Curve = Data.define(:attack, :instant, :decay, :sustain_level, :sustain, :release) do
        def at(held, released)
          return level_after_hold(held) unless released

          start = level_after_hold(held)
          return MAX_ATTENUATION if release.zero? && start >= MAX_ATTENUATION

          (start + (release * released)).clamp(0, MAX_ATTENUATION)
        end

        private

        def level_after_hold(held)
          attack_time = if instant
                          0.0
                        elsif attack.zero?
                          return MAX_ATTENUATION
                        else
                          ATTACK_DIVISOR * Math.log(MAX_ATTENUATION + 1) / attack
                        end
          return (((MAX_ATTENUATION + 1) * Math.exp(-attack * held / ATTACK_DIVISOR)) - 1).clamp(0, MAX_ATTENUATION) if held < attack_time

          held -= attack_time
          decay_time = decay.zero? ? Float::INFINITY : sustain_level / decay
          return decay * held if held < decay_time

          (sustain_level + (sustain * (held - decay_time))).clamp(0, MAX_ATTENUATION)
        end
      end
      private_constant :Curve
    end
  end
end
