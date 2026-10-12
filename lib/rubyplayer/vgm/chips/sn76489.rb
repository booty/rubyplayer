# frozen_string_literal: true

require_relative '../snapshot'
require_relative '../pitch'

module RubyPlayer
  module Vgm
    module Chips
      # Tracks tone, noise, attenuation, and stereo routing for one PSG instance.
      class Sn76489
        CHANNEL_COUNT = 4

        def initialize(clock_hz:, instance: 0, feedback: nil, shift_width: nil,
                       flags: nil, gg_stereo: true, variant: :sn76489)
          @clock_hz = clock_hz
          @instance = instance
          @feedback = feedback
          @shift_width = shift_width
          @flags = flags
          @gg_stereo = gg_stereo
          @variant = variant
          @periods = Array.new(3)
          @volumes = Array.new(CHANNEL_COUNT, 15)
          @noise_control = 0
          @stereo = 0xff
          @latched_channel = nil
          @latched_volume = false
          @last_trigger_samples = Array.new(CHANNEL_COUNT)
        end

        def write(register:, value:, sample:, **_port)
          return unless value.is_a?(Integer) && value.between?(0, 0xff)

          case register
          when :stereo
            before = enabled_states
            @stereo = value
            record_activations(before, sample)
          when :data
            if value.anybits?(0x80)
              channel = (value >> 5) & 0x03
              @latched_channel = channel
              @latched_volume = value.anybits?(0x10)
              before = channel_enabled?(channel)
              write_latched(channel, @latched_volume, value & 0x0f, continuation: false)
            elsif @latched_channel
              channel = @latched_channel
              before = channel_enabled?(channel)
              write_latched(channel, @latched_volume, value & 0x3f, continuation: true)
            end
            @last_trigger_samples[channel] = sample if channel && before == false && channel_enabled?(channel)
          end
        end

        def snapshot(**)
          channels = Array.new(CHANNEL_COUNT) { |channel| channel_snapshot(channel) }
          ChipSnapshot.new(
            id: "sn76489:#{@instance}", name: @variant.to_s.upcase, clock_hz: @clock_hz,
            channels: channels,
            details: { variant: @variant, noise_feedback: @feedback,
                       shift_width: @shift_width, flags: @flags,
                       stereo_register: @gg_stereo ? @stereo : nil }
          )
        end

        def dump_state
          Immutable.deep_freeze({ periods: @periods, volumes: @volumes,
                                  noise_control: @noise_control, stereo: @stereo,
                                  latched_channel: @latched_channel,
                                  latched_volume: @latched_volume,
                                  last_trigger_samples: @last_trigger_samples })
        end

        def restore_state(state)
          @periods = state.fetch(:periods).dup
          @volumes = state.fetch(:volumes).dup
          @noise_control = state.fetch(:noise_control)
          @stereo = state.fetch(:stereo)
          @latched_channel = state.fetch(:latched_channel)
          @latched_volume = state.fetch(:latched_volume)
          @last_trigger_samples = state.fetch(:last_trigger_samples).dup
          self
        end

        private

        def write_latched(channel, volume, data, continuation:)
          if volume
            @volumes[channel] = data & 0x0f
          elsif channel == 3
            @noise_control = data & 0x07
          elsif continuation
            @periods[channel] = (@periods[channel].to_i & 0x0f) | ((data & 0x3f) << 4)
          else
            @periods[channel] = (@periods[channel].to_i & 0x3f0) | (data & 0x0f)
          end
        end

        # Tone-3 coupling is the PSG's register terminology and part of its details schema.
        # rubocop:disable Naming/VariableNumber
        def channel_snapshot(channel)
          route = route_for(channel)
          enabled = channel_enabled?(channel)
          if channel == 3
            type = @noise_control.nobits?(0x04) ? :periodic : :white
            rate = case @noise_control & 0x03
                   when 0 then :clock_512
                   when 1 then :clock_1024
                   when 2 then :clock_2048
                   else :tone_3
                   end
            details = { attenuation: @volumes[channel], route: route,
                        noise_type: type, noise_rate: rate,
                        tone_3_coupled: rate == :tone_3 }
            note = "#{type} / #{rate == :tone_3 ? 'tone 3' : rate.to_s.delete_prefix('clock_')}"
            kind = :noise
            label = 'Noise'
            pitch_hz = nil
          else
            period = @periods[channel]
            pitch_hz = period.nil? ? nil : Pitch.psg_hz(clock_hz: @clock_hz, period: period)
            note_name, cents = Pitch.note_and_cents(pitch_hz)
            details = { period: period, attenuation: @volumes[channel], route: route,
                        pitch_cents: cents,
                        zero_period_uses_maximum_divider: period&.zero? || false }
            note = note_name
            kind = :tone
            label = "PSG #{channel + 1}"
          end

          ChannelSnapshot.new(
            id: "sn76489:#{@instance}:#{channel}", label: label, kind: kind,
            state: enabled ? :enabled : :muted,
            last_trigger_sample: @last_trigger_samples[channel], pitch_hz: pitch_hz,
            note: note, pan: route, patch: nil, details: details
          )
        end
        # rubocop:enable Naming/VariableNumber

        def enabled_states = Array.new(CHANNEL_COUNT) { |channel| channel_enabled?(channel) }

        def record_activations(before, sample)
          before.each_index do |channel|
            @last_trigger_samples[channel] = sample if !before[channel] && channel_enabled?(channel)
          end
        end

        def channel_enabled?(channel)
          @volumes[channel] < 15 && route_for(channel) != :none
        end

        def route_for(channel)
          return :lr unless @gg_stereo

          left = @stereo.anybits?(1 << (channel + 4))
          right = @stereo.anybits?(1 << channel)
          return :lr if left && right
          return :l if left
          return :r if right

          :none
        end
      end
    end
  end
end
