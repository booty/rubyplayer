# frozen_string_literal: true

require_relative 'snapshot'

module RubyPlayer
  module Nsf
    # Turns one snapshot's register blocks into each chip's channels, as
    # libgme plays them: pitch, level, and the settings the live page shows.
    # VRC7 is not here: it goes through the OPLL model (Vrc7).
    module Chips
      # One channel: `voice` is libgme's (its mute bit), `index` its place in
      # the chip's channel list and note history.
      Channel = Data.define(:label, :kind, :voice, :pitch_hz, :details)
      # A chip present in the NSF: `key` names it in snapshot ids.
      Chip = Data.define(:key, :name, :clock_hz, :channels, :details)

      DUTY_PERCENT = [12.5, 25, 50, 75].freeze
      # CPU clocks per noise LFSR step and per DMC bit, by period index
      # (libgme's tables: noise is NTSC-only there).
      NOISE_PERIODS = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068].freeze
      DMC_PERIODS = {
        ntsc: [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54],
        pal: [398, 354, 316, 298, 276, 236, 210, 198, 176, 148, 132, 118, 98, 78, 66, 50]
      }.freeze
      # The short noise mode repeats every 93 steps, so it has a pitch.
      SHORT_NOISE_STEPS = 93
      N163_CHANNELS = 8
      # Namco 163 timing: the enabled channels take turns, one update every
      # 15 CPU clocks, each adding its phase increment to a phase that
      # advances one wave sample per 65,536.
      N163_CLOCKS_PER_UPDATE = 15.0
      N163_PHASE_PER_SAMPLE = 65_536
      # FDS: the wave (64 samples) and modulator advance by their phase
      # increment per CPU clock; a full cycle is 65,536 × 64 phase units.
      FDS_PHASE_PER_CYCLE = 4_194_304.0
      FDS_MASTER_VOLUME = [100, 67, 50, 40].freeze

      module_function

      # Every chip the snapshot's NSF uses, 2A03 first, in libgme's voice order.
      def for(state)
        voices = Voices.new(state.chips)
        chips = [apu(state)]
        chips << vrc6(state, voices.base(:vrc6)) if voices.base(:vrc6)
        chips << n163(state, voices.base(:n163)) if voices.base(:n163)
        chips << s5b(state, voices.base(:s5b)) if voices.base(:s5b)
        chips << fds(state, voices.base(:fds)) if voices.base(:fds)
        chips << mmc5(state, voices.base(:mmc5)) if voices.base(:mmc5)
        chips
      end

      def apu(state)
        regs = state.apu_regs
        channels = [pulse(state, 'Pulse 1', 0, regs.byteslice(0, 4), state.apu_volume[0], state.apu_length[0],
                          enabled: state.apu_status[0] == 1, sweep: true),
                    pulse(state, 'Pulse 2', 1, regs.byteslice(4, 4), state.apu_volume[1], state.apu_length[1],
                          enabled: state.apu_status[1] == 1, sweep: true),
                    triangle(state, regs.byteslice(8, 4)), noise(state, regs.byteslice(12, 4)),
                    dmc(state, regs.byteslice(16, 4))]
        Chip.new(key: '2a03', name: state.pal? ? 'Ricoh 2A07' : 'Ricoh 2A03', clock_hz: state.cpu_clock_hz,
                 channels: channels,
                 details: { pal: state.pal?, driver_hz: state.driver_hz,
                            five_step: state.apu_frame_mode.anybits?(0x80) })
      end

      def mmc5(state, base)
        regs = state.mmc5_regs
        channels = Array.new(2) do |index|
          pulse(state, "MMC5 Pulse #{index + 1}", base + index, regs.byteslice(index * 4, 4),
                state.mmc5_volume[index], state.mmc5_length[index], enabled: state.mmc5_status[index] == 1)
        end
        channels << Channel.new(label: 'MMC5 PCM', kind: :nes_pcm, voice: base + 2, pitch_hz: nil,
                                details: { level: state.mmc5_pcm })
        Chip.new(key: 'mmc5', name: 'Nintendo MMC5', clock_hz: state.cpu_clock_hz, channels: channels, details: {})
      end

      def vrc6(state, base)
        regs = state.vrc6_regs.bytes
        cpu_clock_hz = state.cpu_clock_hz
        pulses = Array.new(2) do |index|
          control, low, high = regs[index * 3, 3]
          period = ((high & 0x0f) << 8) | low
          Channel.new(label: "VRC6 Pulse #{index + 1}", kind: :vrc6_pulse, voice: base + 1 + index,
                      pitch_hz: cpu_clock_hz / (16.0 * (period + 1)),
                      details: { duty_sixteenths: ((control >> 4) & 7) + 1, volume: control & 0x0f,
                                 digitized: control.anybits?(0x80), enabled: high.anybits?(0x80), period: period })
        end
        rate, low, high = regs[6, 3]
        period = ((high & 0x0f) << 8) | low
        saw = Channel.new(label: 'VRC6 Saw', kind: :vrc6_saw, voice: base, pitch_hz: cpu_clock_hz / (14.0 * (period + 1)),
                          details: { rate: rate & 0x3f, enabled: high.anybits?(0x80), period: period })
        Chip.new(key: 'vrc6', name: 'Konami VRC6', clock_hz: cpu_clock_hz, channels: [*pulses, saw], details: {})
      end

      # Namco 163 sound RAM: waves (4-bit samples, two per byte) share it with
      # the channel registers at $40-$7F. Channel 1 sits at $78 and libgme's
      # oscillator 7; enabling n channels enables channels 1..n.
      def n163(state, base)
        ram = state.n163.bytes
        active = state.n163_active
        channels = Array.new(N163_CHANNELS) do |number|
          osc = N163_CHANNELS - 1 - number
          n163_channel(state, ram, osc, base + osc, number, active)
        end
        Chip.new(key: 'n163', name: 'Namco 163', clock_hz: state.cpu_clock_hz, channels: channels,
                 details: { active: active })
      end

      def n163_channel(state, ram, osc, voice, number, active_channel_count)
        reg = ram[0x40 + (osc * 8), 8]
        phase_increment = ((reg[4] & 3) << 16) | (reg[2] << 8) | reg[0]
        # libgme's wave length: 32 samples less 4 per step of bits 2-4.
        wave_length_samples = 32 - (((reg[4] >> 2) & 7) * 4)
        enabled = number < active_channel_count
        if enabled && wave_length_samples.positive? && phase_increment.positive?
          hz = state.cpu_clock_hz * phase_increment /
               (N163_CLOCKS_PER_UPDATE * N163_PHASE_PER_SAMPLE * active_channel_count * wave_length_samples)
        end
        Channel.new(label: "N163 Wave #{number + 1}", kind: :n163_wave, voice: voice, pitch_hz: hz,
                    details: { volume: reg[7] & 0x0f, freq: phase_increment, wave_length: wave_length_samples,
                               wave_address: reg[6], samples: n163_wave(ram, reg[6], wave_length_samples),
                               enabled: enabled })
      end

      # `length` 4-bit samples from nibble `address` on, low nibble first.
      def n163_wave(ram, address, length)
        Array.new(length) do |index|
          nibble = address + index
          (ram[(nibble >> 1) & 0x7f] >> ((nibble & 1) * 4)) & 0x0f
        end
      end

      # Sunsoft 5B: an AY-3-8910 with three square channels. libgme plays
      # their tones only; noise and the envelope generator stay silent.
      def s5b(state, base)
        regs = state.s5b_regs.bytes
        channels = Array.new(3) { |index| s5b_channel(state, regs, index, base + index) }
        Chip.new(key: 's5b', name: 'Sunsoft 5B', clock_hz: state.cpu_clock_hz, channels: channels,
                 details: { noise_period: regs[6] & 0x1f, envelope_period: (regs[12] << 8) | regs[11],
                            envelope_shape: regs[13] & 0x0f })
      end

      def s5b_channel(state, regs, index, voice)
        period = ((regs[(index * 2) + 1] & 0x0f) << 8) | regs[index * 2]
        volume = regs[8 + index]
        Channel.new(label: "5B Square #{'ABC'[index]}", kind: :s5b_square, voice: voice,
                    pitch_hz: state.cpu_clock_hz / (32.0 * [period, 1].max),
                    details: { period: period, volume: volume & 0x0f, envelope: volume.anybits?(0x10),
                               tone: regs[7][index].zero?, noise: regs[7][index + 3].zero? })
      end

      # Famicom Disk System: one 64-step wavetable channel with a volume
      # envelope and a 32-step frequency modulator.
      def fds(state, base)
        regs = state.fds_regs.bytes
        wave_phase_increment = ((regs[3] & 0x0f) << 8) | regs[2]
        pitch_hz = state.cpu_clock_hz * wave_phase_increment / FDS_PHASE_PER_CYCLE if wave_phase_increment.positive?
        channel = Channel.new(label: 'FDS Wave', kind: :fds_wave, voice: base, pitch_hz: pitch_hz,
                              details: { freq: wave_phase_increment, gain: state.fds_env_gain, envelope: fds_envelope(regs[0]),
                                         master_volume: FDS_MASTER_VOLUME[regs[9] & 3], halted: regs[3].anybits?(0x80),
                                         samples: state.fds_wave.bytes, **fds_modulator(state, regs) })
        Chip.new(key: 'fds', name: 'Famicom Disk System', clock_hz: state.cpu_clock_hz, channels: [channel],
                 details: {})
      end

      # The modulator steps through its 64-entry table (32 values, each
      # twice) bending the wave's pitch by up to `mod_depth`.
      def fds_modulator(state, regs)
        modulation_phase_increment = ((regs[7] & 0x0f) << 8) | regs[6]
        { mod_table: state.fds_mod.bytes, mod_depth: state.fds_sweep_gain, mod_freq: modulation_phase_increment,
          mod_enabled: regs[7].nobits?(0x80) && modulation_phase_increment.positive?,
          mod_hz: state.cpu_clock_hz * modulation_phase_increment / FDS_PHASE_PER_CYCLE }
      end

      # $4080: an envelope ramping down or up (bit 6) at speed bits 0-5, or
      # holding (bit 7: a direct gain write, or libgme marking a finished ramp).
      def fds_envelope(register)
        return { mode: :held } if register.anybits?(0x80)

        { mode: register.anybits?(0x40) ? :up : :down, speed: register & 0x3f }
      end

      def pulse(state, label, voice, regs, volume, length_counter_ticks, enabled:, sweep: false)
        control, sweep_reg, low, high = regs.bytes
        period = ((high & 7) << 8) | low
        details = { duty: DUTY_PERCENT[control >> 6], volume: volume, length_counter_ticks: length_counter_ticks, enabled: enabled,
                    **envelope(control), period: period }
        if sweep
          details.merge!(sweep_enabled: sweep_reg.anybits?(0x80), sweep_period: (sweep_reg >> 4) & 7,
                         sweep_down: sweep_reg.anybits?(0x08), sweep_shift: sweep_reg & 7)
        end
        # Periods under 8 are silenced, not ultrasonic.
        Channel.new(label: label, kind: :nes_pulse, voice: voice,
                    pitch_hz: period >= 8 ? state.cpu_clock_hz / (16.0 * (period + 1)) : nil, details: details)
      end

      def triangle(state, regs)
        control, _unused, low, high = regs.bytes
        period = ((high & 7) << 8) | low
        # libgme stops the triangle below period 2 instead of playing it ultrasonic.
        Channel.new(label: 'Triangle', kind: :nes_triangle, voice: 2,
                    pitch_hz: period >= 2 ? state.cpu_clock_hz / (32.0 * (period + 1)) : nil,
                    details: { period: period, linear: state.tri_linear, linear_load: control & 0x7f,
                               held: control.anybits?(0x80), length_counter_ticks: state.apu_length[2],
                               enabled: state.apu_status[2] == 1 })
      end

      def noise(state, regs)
        control, _unused, mode, = regs.bytes
        steps = NOISE_PERIODS[mode & 0x0f]
        short = mode.anybits?(0x80)
        Channel.new(label: 'Noise', kind: :nes_noise, voice: 3,
                    pitch_hz: short ? state.cpu_clock_hz / (steps * SHORT_NOISE_STEPS.to_f) : nil,
                    details: { short: short, period_index: mode & 0x0f, lfsr_hz: state.cpu_clock_hz.fdiv(steps),
                               volume: state.apu_volume[2], length_counter_ticks: state.apu_length[3],
                               enabled: state.apu_status[3] == 1, **envelope(control) })
      end

      def dmc(state, regs)
        control, _load, address, length = regs.bytes
        period = DMC_PERIODS.fetch(state.pal? ? :pal : :ntsc)[control & 0x0f]
        bit_rate = state.cpu_clock_hz.fdiv(period)
        bytes = (length * 16) + 1
        loop = control.anybits?(0x40)
        # A looping sample repeats every `bytes` × 8 bits: that is its pitch
        # (Sunsoft's "DMC bass" plays notes this way).
        Channel.new(label: 'DMC', kind: :nes_dmc, voice: 4, pitch_hz: loop ? bit_rate / (bytes * 8) : nil,
                    details: { rate_index: control & 0x0f, bit_rate: bit_rate, loop: loop, level: state.dmc_dac,
                               sample_address: 0xc000 + (address * 64), sample_length: bytes,
                               bytes_left: state.apu_length[4], address: state.dmc_address,
                               enabled: state.apu_status[4] == 1 })
      end

      # $4000-style control: constant volume (bit 4) or a decaying envelope
      # (period bits 0-3, looping when bit 5 also halts the length counter).
      def envelope(control)
        { constant: control.anybits?(0x10), envelope_period: control & 0x0f, loop: control.anybits?(0x20) }
      end
    end
  end
end
