# frozen_string_literal: true

require_relative '../snapshot'
require_relative '../patch'
require_relative '../pitch'
require_relative '../note_log'

module RubyPlayer
  module Vgm
    module Chips
      # Tracks YM2612 register state and derives its six FM/DAC channel rows.
      class Ym2612
        RECENT_SAMPLES = 4_410
        OPERATOR_OFFSETS = [0, 8, 4, 12].freeze
        OPERATOR_PARAMETER_GROUPS = [0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90].freeze
        PARAMETER_NAMES = %i[dt mul tl rs ar am d1r d2r d1l rr ssg_eg].freeze
        # Channel 3 special-mode registers are not in operator order: A9/AD
        # drive OP1, AA/AE drive OP2, A8/AC drive OP3, and the ordinary A2/A6
        # channel 3 frequency drives OP4.
        SPECIAL_SLOT_OPERATORS = { 0 => 3, 1 => 1, 2 => 2 }.freeze
        # Register 0x22 LFO rates, from the datasheet.
        LFO_HZ = [3.98, 5.56, 6.02, 6.37, 6.88, 9.63, 48.1, 72.2].freeze
        DAC_CHANNEL = 5
        private_constant :SPECIAL_SLOT_OPERATORS, :DAC_CHANNEL

        def initialize(clock_hz:, variant: :ym2612, instance: 0)
          @clock_hz = clock_hz
          @variant = variant
          @instance = instance
          @registers = Array.new(2) { Array.new(0x100) }
          @key_masks = Array.new(6, 0)
          @last_trigger_samples = Array.new(6)
          @release_samples = Array.new(6)
          # Per operator (OP1..OP4 at 0..3): each has its own key, and the
          # live page's levels follow the keyed carriers only.
          @operator_triggers = Array.new(6) { Array.new(4) }
          @operator_releases = Array.new(6) { Array.new(4) }
          @notes = NoteLog.new
          @dac_writes = 0
          # The chip has one A4-A6 high-byte latch shared by all channels on
          # both ports, and one AC-AE latch for special mode. Only the low-byte
          # write commits a frequency; both latches reset to zero.
          @frequency_latch = 0
          @special_latch = 0
          @frequency = Array.new(6)
          @special_frequency = Array.new(3)
          @patch_cache = Array.new(6)
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
            dac_write(value, sample) if port.zero?
          when 0x2b
            @dac_enabled = value.anybits?(0x80) if port.zero?
          when 0xa0..0xa2
            commit_frequency((port * 3) + register - 0xa0, value, sample)
          when 0xa4..0xa6
            @frequency_latch = value
          when 0xa8..0xaa
            @special_frequency[register - 0xa8] = latched_frequency(@special_latch, value) if port.zero?
          when 0xac..0xae
            @special_latch = value if port.zero?
          end
        end

        def snapshot(sample:)
          channels = Array.new(6) { |index| channel_snapshot(index, sample) }
          mode = @registers[0][0x27]
          lfo = register(0, 0x22)
          ChipSnapshot.new(
            id: "ym2612:#{@instance}",
            name: @variant == :ym3438 ? 'YM3438' : 'YM2612',
            clock_hz: @clock_hz,
            channels: channels,
            details: {
              variant: @variant,
              lfo: lfo,
              lfo_enabled: !lfo.nil? && lfo.anybits?(0x08),
              lfo_hz: lfo&.anybits?(0x08) ? LFO_HZ[lfo & 0x07] : nil,
              channel_3_special_mode: !mode.nil? && mode.anybits?(0x40),
              csm_enabled: !mode.nil? && mode.anybits?(0x80),
              **timer_details(mode),
              timer_generated_key_activity: !mode.nil? && mode.anybits?(0x80) ? :unmodeled : nil,
              dac_enabled: @dac_enabled,
              dac_value: @dac_value,
              dac_sample: @dac_sample,
              dac_writes: @dac_writes,
              events: @notes.packed
            }
          )
        end

        def dump_state
          Immutable.deep_freeze({
                                  registers: @registers,
                                  key_masks: @key_masks,
                                  last_trigger_samples: @last_trigger_samples,
                                  release_samples: @release_samples,
                                  operator_triggers: @operator_triggers,
                                  operator_releases: @operator_releases,
                                  notes: @notes.dump_state,
                                  dac_writes: @dac_writes,
                                  frequency_latch: @frequency_latch,
                                  special_latch: @special_latch,
                                  frequency: @frequency,
                                  special_frequency: @special_frequency,
                                  dac_enabled: @dac_enabled,
                                  dac_value: @dac_value,
                                  dac_sample: @dac_sample
                                })
        end

        def restore_state(state)
          @registers = state.fetch(:registers).map(&:dup)
          @key_masks = state.fetch(:key_masks).dup
          @last_trigger_samples = state.fetch(:last_trigger_samples).dup
          @release_samples = state.fetch(:release_samples).dup
          @operator_triggers = state.fetch(:operator_triggers).map(&:dup)
          @operator_releases = state.fetch(:operator_releases).map(&:dup)
          @notes = NoteLog.new.restore_state(state.fetch(:notes))
          @dac_writes = state.fetch(:dac_writes)
          @frequency_latch = state.fetch(:frequency_latch)
          @special_latch = state.fetch(:special_latch)
          @frequency = state.fetch(:frequency).dup
          @special_frequency = state.fetch(:special_frequency).dup
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
          old_mask = @key_masks[channel]
          @key_masks[channel] = new_mask
          record_operator_keys(channel, old_mask, new_mask, sample)
          if new_mask.anybits?(~old_mask)
            @last_trigger_samples[channel] = sample
            @notes.on(channel, sample, midi_for(channel)) unless dac_channel?(channel)
          elsif new_mask.zero? && old_mask.positive?
            @release_samples[channel] = sample
            @notes.off(channel, sample) unless dac_channel?(channel)
          end
        end

        def record_operator_keys(channel, old_mask, new_mask, sample)
          4.times do |operator|
            if new_mask[operator] == 1 && old_mask[operator].zero?
              @operator_triggers[channel][operator] = sample
            elsif new_mask[operator].zero? && old_mask[operator] == 1
              @operator_releases[channel][operator] = sample
            end
          end
        end

        # A burst of DAC writes is one note in the history: it starts with the
        # first write after a gap and ends at the last write before the next gap.
        def dac_write(value, sample)
          if @dac_enabled
            gap = @dac_sample.nil? || sample - @dac_sample > RECENT_SAMPLES
            @notes.off(DAC_CHANNEL, @dac_sample) if gap && @dac_sample
            @notes.on(DAC_CHANNEL, sample, nil) if gap
          end
          @dac_value = value
          @dac_sample = sample
          @dac_writes += 1
        end

        def dac_channel?(channel) = channel == DAC_CHANNEL && @dac_enabled

        def midi_for(channel)
          special = channel == 2 && channel_3_special_mode?
          Pitch.midi(channel_pitch(@frequency[channel], special))
        end

        def commit_frequency(channel, value, sample)
          @frequency[channel] = latched_frequency(@frequency_latch, value)
          @notes.note(channel, sample, midi_for(channel)) if @key_masks[channel].positive?
        end

        def timer_details(mode)
          high = register(0, 0x24)
          timer_a = high && ((high << 2) | (register(0, 0x25).to_i & 3))
          timer_b = register(0, 0x26)
          { timer_a: timer_a, timer_b: timer_b,
            timer_a_hz: timer_a && timer_hz(1024 - timer_a),
            timer_b_hz: timer_b && timer_hz(16 * (256 - timer_b)),
            timers_running: mode.nil? ? [false, false] : [mode.anybits?(0x01), mode.anybits?(0x02)] }
        end

        # Timer periods count in units of 144 master clocks (one FM sample).
        def timer_hz(ticks)
          return unless @clock_hz.is_a?(Numeric) && @clock_hz.positive? && ticks.positive?

          @clock_hz / (144.0 * ticks)
        end

        def latched_frequency(high, low)
          { fnum: ((high & 0x07) << 8) | low, block: (high >> 3) & 0x07 }.freeze
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
            details: { dac_enabled: true, dac_value: @dac_value, dac_sample: @dac_sample, dac_writes: @dac_writes,
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
            release_sample: @release_samples[index],
            operator_triggers: @operator_triggers[index].dup, operator_releases: @operator_releases[index].dup,
            algorithm: base&.then { |value| value & 0x07 },
            feedback: base&.then { |value| (value >> 3) & 0x07 },
            ams: ams_fms&.then { |value| (value >> 4) & 0x03 },
            fms: ams_fms&.then { |value| value & 0x07 },
            special_mode: special,
            special_frequencies: special ? special_frequency_details : nil
          }
        end

        # Snapshots are taken at the UI refresh rate while timbre registers
        # rarely change, so reuse the patch (and its SHA-256) until they do.
        def build_patch(index)
          base = channel_register(index, 0xb0)
          raw_operators = Array.new(4) { |operator| operator_register_bytes(index, operator) }
          key = [base, raw_operators]
          cached_key, cached_patch = @patch_cache[index]
          return cached_patch if cached_key == key

          patch = decode_patch(base, raw_operators)
          @patch_cache[index] = [key, patch]
          patch
        end

        def decode_patch(base, raw_operators)
          algorithm = base&.then { |value| value & 0x07 }
          feedback = base.nil? ? nil : (base >> 3) & 0x07
          operators = raw_operators.each_with_index.map do |fields, operator|
            Operator.new(index: operator + 1, parameters: decode_operator(fields))
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
          by_operator = SPECIAL_SLOT_OPERATORS.to_h { |slot, operator| [operator, @special_frequency[slot]] }
          by_operator[4] = @frequency[2]
          (1..4).map do |operator|
            frequency = by_operator[operator]
            fnum = frequency&.fetch(:fnum)
            block = frequency&.fetch(:block)
            { operator: operator, fnum: fnum, block: block,
              pitch_hz: fnum && Pitch.ym2612_hz(clock_hz: @clock_hz, fnum: fnum, block: block) }
          end
        end
      end
    end
  end
end
