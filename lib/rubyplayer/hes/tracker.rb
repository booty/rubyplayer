# frozen_string_literal: true

require_relative 'snapshot'
require_relative '../chip_tracker'

module RubyPlayer
  module Hes
    # Turns HuC6280 PSG snapshots into the live page's view snapshot (see
    # ChipTracker), so HES gets the VGM page's table, keyboard, and note
    # history.
    class Tracker < ChipTracker
      CHIP_ID = 'huc6280:0'
      CHIP_NAME = 'HuC6280 PSG'
      KEY_ON = 0x80
      DIRECT_DAC = 0x40
      NOISE_ON = 0x80
      VOLUME_MASK = 0x1f
      NOISE_RATE_MASK = 0x1f
      # Only Multi 1-2 (voices 4-5) have a noise generator.
      NOISE_VOICES = [4, 5].freeze
      # A wave cycle is 32 steps of two clocks per period count.
      CLOCKS_PER_WAVE_PERIOD = 64
      # libgme steps the noise LFSR every (32 - rate) * 64 clocks.
      NOISE_STEPS = 32
      KINDS = { wave: :huc_wave, noise: :huc_noise, dda: :huc_dda }.freeze
      # Note history's name for each unpitched mode's sound.
      UNPITCHED = { noise: :noise, dda: :dac }.freeze
      private_constant :KEY_ON, :DIRECT_DAC, :NOISE_ON, :VOLUME_MASK, :NOISE_RATE_MASK, :NOISE_VOICES,
                       :CLOCKS_PER_WAVE_PERIOD, :NOISE_STEPS, :KINDS, :UNPITCHED

      private

      def reset_format_state
        @notes = Vgm::NoteLog.new
      end

      def ingest(native_snapshot, sample)
        VOICES.times do |voice|
          record_note(@notes, voice, voice, native_snapshot, sample, midi_for(native_snapshot, voice),
                      unpitched: UNPITCHED[mode(native_snapshot, voice)])
        end
      end

      def build_view_snapshot(native_snapshot) = view_snapshot(native_snapshot, [chip(native_snapshot)])

      def chip(state)
        Vgm::ChipSnapshot.new(id: CHIP_ID, name: CHIP_NAME, clock_hz: state.cpu_clock_hz,
                              channels: Array.new(VOICES) { |voice| channel(state, voice) },
                              details: chip_details(state))
      end

      def chip_details(state)
        { master_left: state.master_balance >> 4, master_right: state.master_balance & 0x0f,
          vblank_hz: state.cpu_clock_hz.fdiv(state.vblank_period_cycles), events: @notes.packed }
      end

      def channel(state, voice)
        pitch = pitch_hz(state, voice)
        Vgm::ChannelSnapshot.new(
          id: "#{CHIP_ID}:#{voice}", label: VOICE_NAMES[voice], kind: KINDS.fetch(mode(state, voice)),
          state: state.playing[voice] == 1 ? :enabled : :off, last_trigger_sample: @trigger_samples[voice],
          pitch_hz: pitch, note: nil,
          pan: pan_from(left: state.output_left[voice].positive?, right: state.output_right[voice].positive?),
          patch: nil,
          details: { **voice_details(state, voice), release_sample: @release_samples[voice],
                                                    pitch_cents: pitch && Vgm::Pitch.note_and_cents(pitch)&.last }
        )
      end

      def voice_details(state, voice)
        control = state.control[voice]
        balance = state.balance[voice]
        details = { voice: voice, mode: mode(state, voice), key_on: control.anybits?(KEY_ON),
                    volume: control & VOLUME_MASK, period_register: state.period[voice],
                    gain_left: state.output_left[voice], gain_right: state.output_right[voice],
                    balance_left: balance >> 4, balance_right: balance & 0x0f,
                    samples: state.wave_samples(voice) }
        case details[:mode]
        when :noise then details.merge(noise_details(state, voice))
        when :dda then details.merge(dac_sample: state.dac[voice])
        else details
        end
      end

      def noise_details(state, voice)
        rate_code = state.noise[voice] & NOISE_RATE_MASK
        { noise_rate_code: rate_code,
          noise_lfsr_hz: state.cpu_clock_hz.fdiv((NOISE_STEPS - rate_code) * CLOCKS_PER_WAVE_PERIOD) }
      end

      # Noise overrides direct DAC, which overrides the wave, as in libgme's
      # Hes_Osc::run_until.
      def mode(state, voice)
        if NOISE_VOICES.include?(voice) && state.noise[voice].anybits?(NOISE_ON) then :noise
        elsif state.control[voice].anybits?(DIRECT_DAC) then :dda
        else :wave
        end
      end

      def pitch_hz(state, voice)
        period = state.period[voice]
        return unless mode(state, voice) == :wave && period.positive?

        state.cpu_clock_hz.fdiv(CLOCKS_PER_WAVE_PERIOD * period)
      end

      def midi_for(state, voice)
        hz = pitch_hz(state, voice)
        hz && Vgm::Pitch.midi(hz)
      end
    end
  end
end
