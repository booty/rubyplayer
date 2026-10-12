# frozen_string_literal: true

require_relative '../snapshot'
require_relative '../pitch'
require_relative '../patch'

module RubyPlayer
  module Vgm
    module Chips
      # Tracks OPLL melodic programs, custom instruments, and rhythm roles.
      class Ym2413
        RHYTHM_ROLES = {
          6 => [[4, :bass_drum]],
          7 => [[0, :hi_hat], [3, :snare]],
          8 => [[2, :tom], [1, :cymbal]]
        }.freeze

        def initialize(clock_hz:, instance: 0)
          @clock_hz = clock_hz
          @instance = instance
          @registers = Array.new(0x40)
          @last_trigger_samples = Array.new(9)
        end

        def write(register:, value:, sample:, **_port)
          return unless register.is_a?(Integer) && register.between?(0, 0x3f)
          return unless value.is_a?(Integer) && value.between?(0, 0xff)

          previous = @registers[register]
          @registers[register] = value
          case register
          when 0x20..0x28
            channel = register - 0x20
            @last_trigger_samples[channel] = sample if value.anybits?(0x10) && previous.to_i.nobits?(0x10) && !rhythm_channel?(channel)
          when 0x0e
            record_rhythm_triggers(previous.to_i, value, sample)
          end
        end

        def snapshot(sample:)
          channels = Array.new(9) { |index| channel_snapshot(index, sample) }
          ChipSnapshot.new(
            id: "ym2413:#{@instance}", name: 'YM2413 OPLL', clock_hz: @clock_hz,
            channels: channels,
            details: { rhythm_mode: rhythm_enabled?, rhythm_register: register(0x0e) }
          )
        end

        def dump_state
          Immutable.deep_freeze({ registers: @registers,
                                  last_trigger_samples: @last_trigger_samples })
        end

        def restore_state(state)
          @registers = state.fetch(:registers).dup
          @last_trigger_samples = state.fetch(:last_trigger_samples).dup
          self
        end

        private

        def channel_snapshot(channel, _sample)
          return percussion_snapshot(channel) if rhythm_enabled? && channel >= 6

          instrument = register(0x30 + channel)
          program = instrument.nil? ? nil : (instrument >> 4) & 0x0f
          volume = instrument.nil? ? nil : instrument & 0x0f
          control = register(0x20 + channel)
          low = register(0x10 + channel)
          fnum = low.nil? || control.nil? ? nil : ((control & 1) << 8) | low
          block = control.nil? ? nil : (control >> 1) & 0x07
          pitch_hz = fnum && Pitch.ym2413_hz(clock_hz: @clock_hz, fnum: fnum, block: block)
          note, cents = Pitch.note_and_cents(pitch_hz)
          custom = program&.zero? || false
          ChannelSnapshot.new(
            id: channel_id(channel), label: "FM #{channel + 1}", kind: :tone,
            state: control&.anybits?(0x10) ? :key_on : :key_off,
            last_trigger_sample: @last_trigger_samples[channel], pitch_hz: pitch_hz,
            note: note, pan: :lr,
            patch: build_patch(program, channel),
            details: { program_number: custom ? :custom : program,
                       volume: volume, fnum: fnum, block: block,
                       key_on: control&.anybits?(0x10),
                       sustain: control&.anybits?(0x20),
                       pitch_cents: cents, custom_instrument: custom }
          )
        end

        def percussion_snapshot(channel)
          roles = RHYTHM_ROLES.fetch(channel).filter_map do |bit, role|
            role if register(0x0e).to_i.anybits?(1 << bit)
          end
          label = roles.map { |role| role.to_s.split('_').map(&:capitalize).join(' ') }.join(' / ')
          label = "Percussion #{channel - 5}" if label.empty?
          ChannelSnapshot.new(
            id: channel_id(channel), label: label,
            kind: :percussion, state: roles.empty? ? :key_off : :key_on,
            last_trigger_sample: @last_trigger_samples[channel], pitch_hz: nil,
            note: nil, pan: :lr, patch: nil,
            details: { rhythm_mode: true, roles: roles, percussion_keys: register(0x0e) & 0x1f }
          )
        end

        def build_patch(program, channel)
          if program&.zero? || false
            custom_registers = Array.new(8) { |index| register(index) || 0 }
            operators = [
              Operator.new(index: 1, parameters: custom_operator(0)),
              Operator.new(index: 2, parameters: custom_operator(1))
            ]
            Patch.from_bytes(chip: :ym2413, bytes: custom_registers,
                             operators: operators,
                             details: { program: :custom, channel: channel })
          else
            Patch.from_bytes(chip: :ym2413, bytes: [program || 0xff],
                             details: { program: program })
          end
        end

        def custom_operator(index)
          op_register = register(index)
          level_register = register(index.zero? ? 0x02 : 0x03)
          envelope_register = register(index.zero? ? 0x04 : 0x05)
          sustain_register = register(index.zero? ? 0x06 : 0x07)
          operator_fields(index, op_register, level_register, envelope_register, sustain_register)
        end

        def operator_fields(index, op_register, level_register, envelope_register, sustain_register)
          {
            am: bit_field(op_register, 7, 1), pm: bit_field(op_register, 6, 1),
            eg: bit_field(op_register, 5, 1), ksr: bit_field(op_register, 4, 1),
            mul: bit_field(op_register, 0, 0x0f),
            key_scale_level: bit_field(level_register, 6, 0x03),
            total_level: index.zero? ? bit_field(level_register, 0, 0x3f) : nil,
            feedback: index.zero? ? bit_field(register(0x03), 0, 0x07) : nil,
            waveform: bit_field(level_register, index.zero? ? 4 : 3, 1),
            ar: bit_field(envelope_register, 4, 0x0f),
            dr: bit_field(envelope_register, 0, 0x0f),
            sl: bit_field(sustain_register, 4, 0x0f),
            rr: bit_field(sustain_register, 0, 0x0f)
          }
        end

        def bit_field(value, shift, mask)
          value&.then { |register_value| (register_value >> shift) & mask }
        end

        def record_rhythm_triggers(previous, value, sample)
          return unless value.anybits?(0x20)

          RHYTHM_ROLES.each do |channel, roles|
            mask = roles.sum { |bit, _role| 1 << bit }
            rising = (value & mask) & ~(previous & mask)
            @last_trigger_samples[channel] = sample if rising.positive?
          end
        end

        def rhythm_enabled? = register(0x0e).to_i.anybits?(0x20)
        def rhythm_channel?(channel) = rhythm_enabled? && channel >= 6
        def channel_id(channel) = "ym2413:#{@instance}:#{channel}"
        def register(address) = @registers[address]
      end
    end
  end
end
