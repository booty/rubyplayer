# frozen_string_literal: true

require_relative 'snapshot'
require_relative '../vgm/snapshot'
require_relative '../vgm/note_log'
require_relative '../vgm/pitch'

module RubyPlayer
  module Gbs
    # Turns the stream of Game Boy APU snapshots into the channel model the
    # VGM live page draws (Vgm::Snapshot), so GBS gets the same table,
    # keyboard, and note history. It must see every snapshot in order: note
    # starts and stops come from consecutive states, and a note shorter than
    # a render would otherwise be lost.
    #
    # Times are converted from output frames to the 44.1 kHz samples the
    # live page counts in.
    class Tracker
      CHIP_ID = 'gb_dmg:0'
      CHIP_NAME = 'Game Boy APU'
      # Square and wave frequencies: clock / (2048 - x), per the APU's timers.
      SQUARE_HZ = 131_072.0
      WAVE_HZ = 65_536.0
      # Noise LFSR clock: 524288 Hz / divisor / 2^(shift + 1); divisor 0 acts as 0.5.
      NOISE_BASE_HZ = 524_288.0
      KINDS = %i[gb_pulse gb_pulse gb_wave gb_noise].freeze
      DUTY_PERCENT = [12.5, 25, 50, 75].freeze
      # NR32 output level codes: mute, 100%, 50%, 25%.
      WAVE_LEVELS = [0, 100, 50, 25].freeze
      VBLANK_PERIOD = 70_224
      # The NR register offsets ($FF10 + n) each voice uses.
      BASES = [0, 5, 10, 15].freeze
      NR50 = 20
      NR51 = 21
      NR52 = 22
      WAVE_RAM = 32
      private_constant :SQUARE_HZ, :WAVE_HZ, :NOISE_BASE_HZ, :KINDS, :VBLANK_PERIOD, :BASES, :NR50, :NR51,
                       :NR52, :WAVE_RAM

      attr_reader :snapshot, :now_sample

      def initialize
        reset(nil)
      end

      # Feeds an engine Gbs::LiveState. Returns whether the channel model
      # changed (a new snapshot or a new generation).
      def update(live)
        @sample_rate = live.sample_rate
        changed = live.generation != @generation
        reset(live.generation) if changed
        @track_generation = live.track_generation
        @now_sample = to_sample(live.frame)
        live.snapshots.each { |state| ingest(state) }
        return changed unless live.snapshots.any? || (changed && @latest)

        @snapshot = build
        true
      end

      private

      def reset(generation)
        @generation = generation
        @notes = Vgm::NoteLog.new
        @latest = nil
        @playing = 0
        @trigger_samples = Array.new(VOICES)
        @release_samples = Array.new(VOICES)
        @snapshot = nil
        @now_sample = 0
      end

      def to_sample(frame) = frame * Vgm::SAMPLE_RATE / @sample_rate

      def ingest(state)
        sample = to_sample(state.frame)
        VOICES.times do |voice|
          was = @playing[voice] == 1
          now = state.playing[voice] == 1
          midi = midi_for(state, voice)
          if now && (state.triggers[voice] == 1 || !was)
            @trigger_samples[voice] = sample
            @notes.on(voice, sample, midi)
          elsif now
            @notes.note(voice, sample, midi)
          elsif was
            @release_samples[voice] = sample
            @notes.off(voice, sample)
          end
        end
        @playing = state.playing
        @latest = state
      end

      def build
        state = @latest
        Vgm::Snapshot.new(generation: @track_generation, revision: @generation, sample: to_sample(state.frame), status: :ready,
                          message: nil, loop_count: 0, chips: [chip(state)], warnings: [])
      end

      def chip(state)
        Vgm::ChipSnapshot.new(id: CHIP_ID, name: CHIP_NAME, clock_hz: state.clock_rate,
                              channels: Array.new(VOICES) { |voice| channel(state, voice) },
                              details: chip_details(state))
      end

      def chip_details(state)
        regs = state.regs
        { power: regs[NR52][7] == 1, master_left: (regs[NR50] >> 4) & 7, master_right: regs[NR50] & 7,
          driver_hz: state.driver_hz, vblank_driver: state.play_period == VBLANK_PERIOD, events: @notes.packed }
      end

      def channel(state, voice)
        pitch = pitch_hz(state, voice)
        Vgm::ChannelSnapshot.new(
          id: "#{CHIP_ID}:#{voice}", label: VOICE_NAMES[voice], kind: KINDS[voice],
          state: state.playing[voice] == 1 ? :enabled : :off, last_trigger_sample: @trigger_samples[voice],
          pitch_hz: pitch, note: nil, pan: pan(state, voice), patch: nil,
          details: { **voice_details(state, voice), release_sample: @release_samples[voice],
                                                    pitch_cents: pitch && Vgm::Pitch.note_and_cents(pitch)&.last }
        )
      end

      def voice_details(state, voice)
        regs = state.regs
        base = BASES[voice]
        # Length counters load 64 - NRx1 (wave: 256 - NR31) ticks of 1/256 s.
        load = KINDS[voice] == :gb_wave ? 256 - regs[base + 1] : 64 - (regs[base + 1] & 0x3f)
        common = { volume: state.volume[voice], length: state.length[voice], length_load: load,
                   length_enabled: regs[base + 4][6] == 1, enabled: state.enabled[voice] == 1,
                   frequency: frequency(regs, base) }
        case KINDS[voice]
        when :gb_pulse then common.merge(pulse_details(state, voice, base))
        when :gb_wave then common.merge(wave_details(regs))
        else common.merge(envelope(regs[base + 2])).merge(noise_details(regs[base + 3]))
        end
      end

      def pulse_details(state, voice, base)
        regs = state.regs
        details = { duty: DUTY_PERCENT[regs[base + 1] >> 6], **envelope(regs[base + 2]) }
        return details unless voice.zero?

        sweep = regs[base]
        details.merge(sweep_pace: (sweep >> 4) & 7, sweep_down: sweep[3] == 1, sweep_shift: sweep & 7,
                      sweep_freq: state.sweep_freq)
      end

      # NRx2: starting volume, direction, and steps every pace/64 s (0: held).
      def envelope(register)
        { initial_volume: register >> 4, envelope_up: register[3] == 1, envelope_pace: register & 7,
          dac: register.anybits?(0xf8) }
      end

      def wave_details(regs)
        samples = regs[WAVE_RAM, 16].flat_map { |byte| [byte >> 4, byte & 0x0f] }
        { dac: regs[10][7] == 1, level: WAVE_LEVELS[(regs[12] >> 5) & 3], samples: samples }
      end

      def noise_details(register)
        shift = register >> 4
        divisor = register & 7
        { clock_shift: shift, divisor: divisor, width: register[3] == 1 ? 7 : 15,
          lfsr_hz: NOISE_BASE_HZ / (divisor.zero? ? 0.5 : divisor) / (2**(shift + 1)) }
      end

      def frequency(regs, base) = ((regs[base + 4] & 7) << 8) | regs[base + 3]

      def pitch_hz(state, voice)
        regs = state.regs
        case KINDS[voice]
        when :gb_pulse then SQUARE_HZ / (2048 - frequency(regs, BASES[voice]))
        when :gb_wave then WAVE_HZ / (2048 - frequency(regs, BASES[voice]))
        else
          # 7-bit noise repeats every 127 steps, so it has a pitch.
          noise = noise_details(regs[BASES[voice] + 3])
          noise[:lfsr_hz] / 127 if noise[:width] == 7
        end
      end

      def midi_for(state, voice)
        hz = pitch_hz(state, voice)
        hz && Vgm::Pitch.midi(hz)
      end

      # NR51: bit n sends voice n to the right output, bit n + 4 to the left.
      def pan(state, voice)
        routing = state.regs[NR51]
        left = routing[voice + 4] == 1
        right = routing[voice] == 1
        if left && right then :lr
        elsif left then :l
        elsif right then :r
        else :none
        end
      end
    end
  end
end
