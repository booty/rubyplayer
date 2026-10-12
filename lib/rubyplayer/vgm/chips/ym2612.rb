# frozen_string_literal: true

require_relative '../snapshot'
require_relative '../patch'
require_relative '../pitch'

module RubyPlayer
  module Vgm
    module Chips
      # Tracks YM2612 register state and derives its six FM/DAC channel rows.
      class Ym2612
        RECENT_SAMPLES = 4_410
        OPERATOR_OFFSETS = [0, 8, 4, 12].freeze
        OPERATOR_PARAMETER_GROUPS = [0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90].freeze
        PARAMETER_NAMES = %i[dt mul tl rs ar am d1r d2r d1l rr ssg_eg].freeze

        def initialize(clock_hz:, variant: :ym2612, instance: 0)
          @clock_hz = clock_hz
          @variant = variant
          @instance = instance
          @registers = Array.new(2) { Array.new(0x100) }
          @key_masks = Array.new(6, 0)
          @last_trigger_samples = Array.new(6)
          @pending_frequency_high = Array.new(6)
          @frequency = Array.new(6)
          @special_low = Array.new(3)
          @special_high = Array.new(3)
          @dac_enabled = false
          @dac_value = nil
          @dac_sample = nil
        end

        def write(port:, register:, value:, sample:)
          return unless port.is_a?(Integer) && port.between?(0, 1)
          return unless register.is_a?(Integer) && register.between?(0, 0xff)
          return unless value.is_a?(Integer) && value.between?(0, 0xff)

          @registers[port][register] = value
          case register
          when 0x28
            key_on(value, sample) if port.zero?
          when 0x2a
            if port.zero?
              @dac_value = value
              @dac_sample = sample
            end
          when 0x2b
            @dac_enabled = value.anybits?(0x80) if port.zero?
          when 0xa0..0xa2
            commit_frequency(port, register - 0xa0, value)
          when 0xa4..0xa6
            channel = (port * 3) + register - 0xa4
            @pending_frequency_high[channel] = value
          when 0xa8..0xaa
            @special_low[register - 0xa8] = value if port.zero?
          when 0xac..0xae
            @special_high[register - 0xac] = value if port.zero?
          end
        end

        def snapshot(sample:)
          channels = Array.new(6) { |index| channel_snapshot(index, sample) }
          mode = @registers[0][0x27]
          timer_a = register(0, 0x24)
          timer_a_low = register(0, 0x25)
          timer_b = register(0, 0x26)
          ChipSnapshot.new(
            id: "ym2612:#{@instance}",
            name: @variant == :ym3438 ? 'YM3438' : 'YM2612',
            clock_hz: @clock_hz,
            channels: channels,
            details: {
              variant: @variant,
              lfo: register(0, 0x22),
              lfo_enabled: !register(0, 0x22).nil? && register(0, 0x22).anybits?(0x08),
              channel_3_special_mode: !mode.nil? && mode.anybits?(0x40),
              csm_enabled: !mode.nil? && mode.anybits?(0x80),
              timer_a: timer_a.nil? ? nil : ((timer_a << 2) | ((timer_a_low || 0) & 3)),
              timer_b: timer_b,
              timer_generated_key_activity: !mode.nil? && mode.anybits?(0x80) ? :unmodeled : nil,
              dac_enabled: @dac_enabled,
              dac_value: @dac_value,
              dac_sample: @dac_sample
            }
          )
        end

        def dump_state
          Immutable.deep_freeze({
                                  registers: @registers,
                                  key_masks: @key_masks,
                                  last_trigger_samples: @last_trigger_samples,
                                  pending_frequency_high: @pending_frequency_high,
                                  frequency: @frequency,
                                  special_low: @special_low,
                                  special_high: @special_high,
                                  dac_enabled: @dac_enabled,
                                  dac_value: @dac_value,
                                  dac_sample: @dac_sample
                                })
        end

        def restore_state(state)
          @registers = state.fetch(:registers).map(&:dup)
          @key_masks = state.fetch(:key_masks).dup
          @last_trigger_samples = state.fetch(:last_trigger_samples).dup
          @pending_frequency_high = state.fetch(:pending_frequency_high).dup
          @frequency = state.fetch(:frequency).map { |item| item&.dup }
          @special_low = state.fetch(:special_low).dup
          @special_high = state.fetch(:special_high).dup
          @dac_enabled = state.fetch(:dac_enabled)
          @dac_value = state.fetch(:dac_value)
          @dac_sample = state.fetch(:dac_sample)
          self
        end

        private

        def key_on(value, sample)
          channel_code = value & 0x03
          return if channel_code == 3

          channel = (((value >> 2) & 1) * 3) + channel_code
          new_mask = (value >> 4) & 0x0f
          @last_trigger_samples[channel] = sample if new_mask.anybits?(~@key_masks[channel])
          @key_masks[channel] = new_mask
        end

        def commit_frequency(port, local_channel, low)
          channel = (port * 3) + local_channel
          high = @pending_frequency_high[channel] || @frequency[channel]&.fetch(:high, 0) || 0
          @frequency[channel] = {
            high: high,
            fnum: ((high & 0x07) << 8) | low,
            block: (high >> 3) & 0x07
          }
        end

        def channel_snapshot(index, sample)
          return dac_snapshot(index, sample) if index == 5 && @dac_enabled

          frequency = @frequency[index]
          special = index == 2 && channel_3_special_mode?
          pitch_hz = channel_pitch(frequency, special)
          note, cents = Pitch.note_and_cents(pitch_hz)
          key_mask = @key_masks[index]
          ChannelSnapshot.new(
            id: "ym2612:#{@instance}:#{index}", label: "FM #{index + 1}", kind: :fm,
            state: key_mask.positive? ? :key_on : :key_off,
            last_trigger_sample: @last_trigger_samples[index], pitch_hz: pitch_hz,
            note: special ? :special : note, pan: pan_for(index),
            patch: build_patch(index), details: channel_details(index, frequency, special, cents)
          )
        end

        def dac_snapshot(index, sample)
          recent = @dac_sample && sample - @dac_sample <= RECENT_SAMPLES
          ChannelSnapshot.new(
            id: "ym2612:#{@instance}:#{index}", label: 'FM 6 / DAC', kind: :pcm,
            state: recent ? :data : :idle, last_trigger_sample: @dac_sample,
            pitch_hz: nil, note: 'PCM', pan: pan_for(index), patch: nil,
            details: { dac_enabled: true, dac_value: @dac_value, dac_sample: @dac_sample,
                       fm_key_mask: @key_masks[index], fm_patch: build_patch(index) }
          )
        end

        def channel_pitch(frequency, special)
          return if special || frequency.nil?

          Pitch.ym2612_hz(clock_hz: @clock_hz, fnum: frequency[:fnum],
                          block: frequency[:block])
        end

        def channel_details(index, frequency, special, cents)
          base = channel_register(index, 0xb0)
          ams_fms = channel_register(index, 0xb4)
          {
            key_mask: @key_masks[index], frequency: frequency, pitch_cents: cents,
            algorithm: base&.then { |value| value & 0x07 },
            feedback: base&.then { |value| (value >> 3) & 0x07 },
            ams: ams_fms&.then { |value| (value >> 4) & 0x03 },
            fms: ams_fms&.then { |value| value & 0x07 },
            special_mode: special,
            special_frequencies: special ? special_frequency_details : nil
          }
        end

        def build_patch(index)
          base = channel_register(index, 0xb0)
          algorithm = base&.then { |value| value & 0x07 }
          feedback = base.nil? ? nil : (base >> 3) & 0x07
          operators = Array.new(4) do |operator|
            fields = operator_register_bytes(index, operator)
            values = decode_operator(fields)
            Operator.new(index: operator + 1, parameters: values)
          end
          bytes = [algorithm || 0xff, feedback || 0xff]
          operators.each do |operator|
            PARAMETER_NAMES.each { |field| bytes << (operator.parameters.fetch(field, nil) || 0xff) }
          end
          Patch.from_bytes(chip: :ym2612, bytes: bytes, algorithm: algorithm,
                           feedback: feedback, operators: operators,
                           details: { patch_signature: true })
        end

        def operator_register_bytes(index, operator)
          port = index / 3
          local_channel = index % 3
          offset = OPERATOR_OFFSETS.fetch(operator)
          OPERATOR_PARAMETER_GROUPS.map do |group|
            @registers[port][group + offset + local_channel]
          end
        end

        def decode_operator(raw)
          dt_mul, tl, rs_ar, am_d1r, d2r, d1l_rr, ssg_eg = raw
          {
            dt: dt_mul.nil? ? nil : (dt_mul >> 4) & 0x07,
            mul: dt_mul.nil? ? nil : (dt_mul & 0x0f),
            tl: tl.nil? ? nil : (tl & 0x7f),
            rs: rs_ar.nil? ? nil : (rs_ar >> 6) & 0x03,
            ar: rs_ar.nil? ? nil : (rs_ar & 0x1f),
            am: am_d1r.nil? ? nil : (am_d1r >> 7) & 1,
            d1r: am_d1r.nil? ? nil : (am_d1r & 0x1f),
            d2r: d2r.nil? ? nil : (d2r & 0x1f),
            d1l: d1l_rr.nil? ? nil : (d1l_rr >> 4) & 0x0f,
            rr: d1l_rr.nil? ? nil : (d1l_rr & 0x0f),
            ssg_eg: ssg_eg.nil? ? nil : (ssg_eg & 0x0f)
          }
        end

        def channel_register(index, base)
          port = index / 3
          local_channel = index % 3
          register(port, base + local_channel)
        end

        def register(port, address)
          @registers[port][address]
        end

        def pan_for(index)
          value = channel_register(index, 0xb4)
          return nil unless value

          left = value.anybits?(0x80)
          right = value.anybits?(0x40)
          return :lr if left && right
          return :l if left
          return :r if right

          :none
        end

        def channel_3_special_mode?
          mode = register(0, 0x27)
          !mode.nil? && mode.anybits?(0x40)
        end

        def special_frequency_details
          Array.new(3) do |operator|
            high = @special_high[operator]
            low = @special_low[operator]
            fnum = high.nil? || low.nil? ? nil : (((high & 0x07) << 8) | low)
            block = high.nil? ? nil : ((high >> 3) & 0x07)
            { operator: operator + 1, fnum: fnum, block: block,
              pitch_hz: fnum && Pitch.ym2612_hz(clock_hz: @clock_hz, fnum: fnum, block: block) }
          end
        end
      end
    end
  end
end
