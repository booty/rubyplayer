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
      MAX_ATTENUATION_STEPS = 1023
      DB_PER_STEP = 96.0 / 1024
      # OPN2 keycode from block and the top four F-number bits (MAME opn_fktable).
      OPN_FKTABLE = [0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 3, 3, 3, 3, 3, 3].freeze
      # Which operators reach the output, per YM2612 algorithm.
      CARRIERS = [[4], [4], [4], [4], [2, 4], [2, 3, 4], [2, 3, 4], [1, 2, 3, 4]].freeze
      # Average per-tick increments for rate codes below 48 (MAME eg_inc
      # rows), indexed by rate code % 4.
      LOW_RATE_INCREMENTS = [0.5, 0.625, 0.75, 0.875].freeze
      # The attack recurrence a -= (a + 1) * inc / 16 integrates to
      # a(t) + 1 = 1024 * exp(-inc_rate * t / 16).
      ATTACK_DIVISOR = 16.0
      INSTANT_ATTACK_RATE_CODE = 62
      # OPLL key-off with the sustain flag set releases at this fixed rate.
      OPLL_SUSTAIN_RELEASE_RATE = 5
      # ROM instruments have no readable rates: assume a quick fade on key-off.
      OPLL_ROM_RELEASE_SECONDS = 0.3

      module_function

      def to_db(attenuation_steps) = -attenuation_steps.clamp(0, MAX_ATTENUATION_STEPS) * DB_PER_STEP

      def opn_keycode(fnum:, block:) = (block << 2) | OPN_FKTABLE.fetch((fnum >> 7) & 0x0f)

      # EG steps per second for an effective rate code 0..63. The code is
      # an index into the chip's rate table, not itself a rate.
      def steps_per_second(effective_rate_code, envelope_tick_hz)
        return 0.0 if effective_rate_code < 2

        effective_rate_code = effective_rate_code.clamp(0, 63)
        steps_per_tick = if effective_rate_code < 48
                           LOW_RATE_INCREMENTS[effective_rate_code % 4] / (2**(11 - (effective_rate_code / 4)))
                         elsif effective_rate_code < 60
                           (2**((effective_rate_code - 48) / 4)) * (1 + ((effective_rate_code % 4) * 0.25))
                         else
                           8.0
                         end
        steps_per_tick * envelope_tick_hz
      end

      # One YM2612 operator's attenuation including its total level, or
      # MAX_ATTENUATION_STEPS before any key-on. release_elapsed_seconds is
      # nil while the key is held.
      def opn_operator(parameters, keycode:, clock_hz:, held_seconds:, release_elapsed_seconds: nil)
        total(opn_curve(parameters, keycode, clock_hz).at(held_seconds, release_elapsed_seconds),
              parameters[:tl].to_i * 8)
      end

      def opn_curve(parameters, keycode, clock_hz)
        envelope_tick_hz = clock_hz / 144.0 / 3
        scale = keycode >> (3 - parameters.fetch(:rs, 0).to_i)
        effective_rate_code = ->(rate) { rate.to_i.zero? ? 0 : ((2 * rate.to_i) + scale).clamp(0, 63) }
        steps_per_second_for = ->(rate) { steps_per_second(effective_rate_code.call(rate), envelope_tick_hz) }
        # Release has no zero rate: RR 0 is rate 2 plus key scaling, a slow
        # but finite fade (MAME fm.cpp sets rr = 34 + (RR << 2)).
        release_rate_code = ((4 * parameters[:rr].to_i) + 2 + scale).clamp(0, 63)
        Curve.new(attack_steps_per_second: steps_per_second_for.call(parameters[:ar]),
                  instant_attack: effective_rate_code.call(parameters[:ar]) >= INSTANT_ATTACK_RATE_CODE,
                  decay_steps_per_second: steps_per_second_for.call(parameters[:d1r]),
                  sustain_attenuation_steps: sustain_attenuation_steps(parameters[:d1l]),
                  sustain_steps_per_second: steps_per_second_for.call(parameters[:d2r]),
                  release_steps_per_second: steps_per_second(release_rate_code, envelope_tick_hz))
      end

      # Loudest carrier of a YM2612 channel, as an attenuation. Each
      # operator has its own key, so `timings` holds [held_seconds,
      # release_elapsed_seconds] per operator (index 1..4 at 0..3);
      # held_seconds is nil for one never keyed.
      def opn_channel(patch, keycode:, clock_hz:, timings:)
        return MAX_ATTENUATION_STEPS unless patch&.algorithm

        CARRIERS.fetch(patch.algorithm).map do |index|
          operator = patch.operators.find { |item| item.index == index }
          held_seconds, release_elapsed_seconds = timings[index - 1]
          next MAX_ATTENUATION_STEPS unless operator && held_seconds

          opn_operator(operator.parameters, keycode: keycode, clock_hz: clock_hz, held_seconds: held_seconds,
                                            release_elapsed_seconds: release_elapsed_seconds)
        end.min
      end

      # YM2413 carrier with readable (custom) rates. Percussive patches
      # (EG type 0) keep decaying at the release rate while held.
      def opll_custom(parameters, block:, clock_hz:, volume:, held_seconds:, release_elapsed_seconds: nil,
                      sustain_flag: false)
        curve = opll_curve(parameters, block, clock_hz, sustain_flag)
        total(curve.at(held_seconds, release_elapsed_seconds), volume.to_i * 32)
      end

      def opll_curve(parameters, block, clock_hz, sustain_flag)
        envelope_tick_hz = clock_hz / 72.0
        scale = parameters[:ksr].to_i == 1 ? block * 2 : (block * 2) >> 2
        steps_per_second_for = lambda do |rate|
          effective_rate_code = rate.to_i.zero? ? 0 : ((4 * rate.to_i) + scale).clamp(0, 63)
          steps_per_second(effective_rate_code, envelope_tick_hz)
        end
        percussive = parameters[:eg].to_i.zero?
        Curve.new(attack_steps_per_second: steps_per_second_for.call(parameters[:ar]),
                  instant_attack: parameters[:ar].to_i == 15,
                  decay_steps_per_second: steps_per_second_for.call(parameters[:dr]),
                  sustain_attenuation_steps: sustain_attenuation_steps(parameters[:sl]),
                  sustain_steps_per_second: percussive ? steps_per_second_for.call(parameters[:rr]) : 0.0,
                  release_steps_per_second:
                    steps_per_second_for.call(sustain_flag ? OPLL_SUSTAIN_RELEASE_RATE : parameters[:rr]))
      end

      # ROM instruments: the volume register while held, then a short fade.
      def opll_rom(volume:, release_elapsed_seconds: nil)
        volume_attenuation_steps = volume.to_i * 32
        return total(0, volume_attenuation_steps) unless release_elapsed_seconds

        release_attenuation_steps = release_elapsed_seconds / OPLL_ROM_RELEASE_SECONDS * MAX_ATTENUATION_STEPS
        total(release_attenuation_steps.round, volume_attenuation_steps)
      end

      # SN76489 attenuation is direct: 2 dB per step, 15 is off.
      def psg(attenuation_register)
        return MAX_ATTENUATION_STEPS if attenuation_register.nil? || attenuation_register >= 15

        (attenuation_register * 2 / DB_PER_STEP).round
      end

      # D1L/SL 15 means "all the way down" (-93 dB), not 15 * 3 dB.
      def sustain_attenuation_steps(sustain_level)
        sustain_level = sustain_level.to_i
        sustain_level >= 15 ? MAX_ATTENUATION_STEPS : sustain_level * 32
      end

      def total(envelope_steps, offset_steps) = (envelope_steps + offset_steps).round.clamp(0, MAX_ATTENUATION_STEPS)

      # Attack, decay to the sustain level, sustain slope, and release
      # speeds, plus the attenuation the decay stops at.
      Curve = Data.define(:attack_steps_per_second, :instant_attack, :decay_steps_per_second,
                          :sustain_attenuation_steps, :sustain_steps_per_second, :release_steps_per_second) do
        def at(held_seconds, release_elapsed_seconds)
          held_attenuation_steps = attenuation_after_hold(held_seconds)
          return held_attenuation_steps unless release_elapsed_seconds
          return MAX_ATTENUATION_STEPS if release_steps_per_second.zero? && held_attenuation_steps >= MAX_ATTENUATION_STEPS

          release_attenuation_steps = release_steps_per_second * release_elapsed_seconds
          (held_attenuation_steps + release_attenuation_steps).clamp(0, MAX_ATTENUATION_STEPS)
        end

        private

        def attenuation_after_hold(held_seconds)
          return MAX_ATTENUATION_STEPS if !instant_attack && attack_steps_per_second.zero?

          attack_seconds = instant_attack ? 0.0 : ATTACK_DIVISOR * Math.log(MAX_ATTENUATION_STEPS + 1) / attack_steps_per_second
          return attack_attenuation_steps(held_seconds) if held_seconds < attack_seconds

          decay_elapsed_seconds = held_seconds - attack_seconds
          decay_seconds = if decay_steps_per_second.zero?
                            Float::INFINITY
                          else
                            sustain_attenuation_steps / decay_steps_per_second
                          end
          return decay_steps_per_second * decay_elapsed_seconds if decay_elapsed_seconds < decay_seconds

          sustain_elapsed_seconds = decay_elapsed_seconds - decay_seconds
          (sustain_attenuation_steps + (sustain_steps_per_second * sustain_elapsed_seconds))
            .clamp(0, MAX_ATTENUATION_STEPS)
        end

        def attack_attenuation_steps(held_seconds)
          attenuation_plus_one = (MAX_ATTENUATION_STEPS + 1) *
                                 Math.exp(-attack_steps_per_second * held_seconds / ATTACK_DIVISOR)
          (attenuation_plus_one - 1).clamp(0, MAX_ATTENUATION_STEPS)
        end
      end
      private_constant :Curve
    end
  end
end
