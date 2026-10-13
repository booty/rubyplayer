# frozen_string_literal: true

module RubyPlayer
  module UI
    # NES and Famicom parts of ChipLiveView (NSF tracks): chip lines,
    # instrument text, levels, and voice and detail panels for the 2A03 and
    # the VRC6, Namco 163, Sunsoft 5B, FDS, and MMC5 expansion chips. Their
    # state is read from the emulator, so levels are exact. (VRC7 channels
    # are OPLL channels and use the FM panels.) Relies on ChipLiveView's
    # line/title/fit/format helpers.
    module NesLivePanels
      NES_KINDS = %i[nes_pulse nes_triangle nes_noise nes_dmc nes_pcm vrc6_pulse vrc6_saw n163_wave s5b_square
                     fds_wave].freeze
      # The 2A03 frame counter's quarter-frame rate: envelopes and the
      # triangle's linear counter step at it, length counters at half of it.
      QUARTER_FRAME_HZ = { ntsc: 1_789_773 / 7458.0, pal: 1_662_607 / 8314.0 }.freeze
      NES_DUTY_WAVES = { 12.5 => '▔▁▁▁▁▁▁▁', 25 => '▔▔▁▁▁▁▁▁', 50 => '▔▔▔▔▁▁▁▁', 75 => '▔▔▔▔▔▔▁▁' }.freeze
      # Sunsoft 5B (AY-3-8910) volume steps are about 3 dB apart.
      S5B_DB_PER_STEP = 3.0
      # The VRC6 saw accumulator wraps above 255: rates past 42 clip.
      VRC6_SAW_FULL_RATE = 42
      NES_NO_DETAIL = { nes_dmc: 'Delta PCM: each sample bit steps the level up or down by 2',
                        nes_pcm: 'Raw PCM: the level is the last sample written',
                        vrc6_pulse: 'No envelope: the level is the volume register',
                        s5b_square: 'No envelope (libgme does not play the 5B envelope)' }.freeze
      NES_GRAPH_ROWS = 8

      private

      def nes_kind?(channel) = NES_KINDS.include?(channel.kind)
      def nes_chip?(chip) = %w[2a03 vrc6 n163 s5b fds mmc5].include?(chip.id.split(':').first)

      def nes_summary(chip)
        details = chip.details
        case chip.id.split(':').first
        when '2a03'
          driver = details[:driver_hz] ? format('driver %.1f Hz', details[:driver_hz]) : 'driver --'
          [chip.name, format_clock(chip.clock_hz), details[:pal] ? 'PAL' : 'NTSC',
           "frame counter #{details[:five_step] ? '5' : '4'}-step", driver].join(' · ')
        when 'n163' then [chip.name,
                          "#{details[:active]} of 8 channels enabled (each runs 1/#{details[:active]} as often)"].join(' · ')
        when 's5b' then [chip.name, format_clock(chip.clock_hz), 'tone only: libgme skips noise and envelope'].join(' · ')
        else [chip.name, format_clock(chip.clock_hz)].join(' · ')
        end
      end

      def vrc7_summary(chip) = [chip.name, format_clock(chip.clock_hz), '6 FM channels (VRC7 instrument ROM)'].join(' · ')

      # Instrument wordings, longest first, by kind (nes_pulse_texts, ...).
      def nes_instrument_texts(channel) = send(:"#{channel.kind}_texts", channel.details)

      def nes_pulse_texts(details)
        duty = "#{nes_duty(details)} duty"
        sweep = nes_sweep_text(details)
        ["#{duty} · #{nes_envelope_text(details)}#{" · #{sweep}" if sweep}", "#{duty} · #{nes_envelope_text(details)}",
         "#{duty} · #{nes_envelope_short(details)}", "#{nes_duty(details)} #{nes_envelope_short(details)}"]
      end

      def nes_triangle_texts(details)
        ["triangle · linear #{details[:linear]}/#{details[:linear_load]} · length #{details[:length]}",
         "triangle · linear #{details[:linear]}", 'triangle']
      end

      def nes_noise_texts(details)
        kind = details[:short] ? 'short (tonal)' : 'long (hiss)'
        ["#{kind} noise · #{format_hz(details[:lfsr_hz])} · #{nes_envelope_text(details)}",
         "#{kind} · #{nes_envelope_short(details)}", "#{details[:short] ? 'short' : 'long'} #{nes_envelope_short(details)}"]
      end

      def nes_dmc_texts(details)
        sample = "DPCM #{format('$%04X', details[:sample_address])}"
        ["#{sample} · #{details[:sample_length]} B · #{format_hz(details[:bit_rate])}#{' · loop' if details[:loop]}",
         "#{sample} · #{format_hz(details[:bit_rate])}", 'DPCM']
      end

      def nes_pcm_texts(details) = ["PCM level #{details[:level]}", 'PCM']

      def vrc6_pulse_texts(details)
        duty = details[:digitized] ? 'DAC mode' : "#{details[:duty_sixteenths]}/16 duty"
        ["#{duty} · vol #{details[:volume]}", "#{duty} v#{details[:volume]}"]
      end

      def vrc6_saw_texts(details) = ["sawtooth · rate #{details[:rate]}/#{VRC6_SAW_FULL_RATE}", "saw r#{details[:rate]}"]

      def n163_wave_texts(details)
        return ['disabled (channel count)', 'disabled'] unless details[:enabled]

        ["wave #{sample_sparkline(details[:samples], 15)} · #{details[:wave_length]} steps · vol #{details[:volume]}",
         "#{details[:wave_length]}-step wave · vol #{details[:volume]}", "wave v#{details[:volume]}"]
      end

      def s5b_square_texts(details)
        volume = details[:envelope] ? 'envelope (silent in libgme)' : "vol #{details[:volume]}"
        mix = [('tone' if details[:tone]), ('noise' if details[:noise])].compact.join('+')
        mix = 'off' if mix.empty?
        ["#{mix} · #{volume}", "#{mix} #{volume}"]
      end

      def fds_wave_texts(details)
        ["wave #{sample_sparkline(details[:samples], 63)} · gain #{details[:gain]} · #{fds_mod_text(details)}",
         "64-step wave · gain #{details[:gain]}", "wave g#{details[:gain]}"]
      end

      # The volume being output, as an attenuation like the other chips'.
      def nes_attenuation(channel)
        return Vgm::Envelope::MAX_ATTENUATION unless channel.state == :enabled

        amplitude_attenuation(nes_amplitude(channel))
      end

      def nes_amplitude(channel)
        details = channel.details
        case channel.kind
        when :nes_pulse, :nes_noise, :vrc6_pulse, :n163_wave then details[:volume] / 15.0
        when :nes_triangle then 1.0
        when :nes_dmc then details[:level] / 127.0
        when :nes_pcm then details[:level] / 255.0
        when :vrc6_saw then [details[:rate].fdiv(VRC6_SAW_FULL_RATE), 1.0].min
        when :s5b_square then details[:volume].zero? ? 0.0 : 10**(-S5B_DB_PER_STEP * (15 - details[:volume]) / 20)
        when :fds_wave then [details[:gain], 32].min / 32.0 * details[:master_volume] / 100.0
        else 0.0
        end
      end

      def amplitude_attenuation(amplitude)
        return Vgm::Envelope::MAX_ATTENUATION unless amplitude.positive?

        (-20 * Math.log10(amplitude) / Vgm::Envelope::DB_PER_STEP).round
      end

      # The voice panel, by kind (nes_pulse_lines, ...).
      def nes_voice_lines(row, width) = send(:"#{row.channel.kind}_lines", row, row.channel.details, width)

      def nes_pitch(channel) = "#{channel.pitch_hz ? format_hz(channel.pitch_hz) : '--'} · #{note_text(channel)}"

      def nes_pulse_lines(row, details, width)
        channel = row.channel
        lines = [title("#{channel.label} · #{nes_duty(details)} duty square"),
                 line("Period #{details[:period]} · #{nes_pitch(channel)}"),
                 line("Volume #{details[:volume]}/15 now · #{nes_envelope_text(details)}"), line(nes_length_text(row))]
        lines << line(nes_sweep_text(details) || 'Sweep off') if details.key?(:sweep_enabled)
        lines << line(NES_DUTY_WAVES.fetch(details[:duty]).*((width / 8) + 1)[0, width], color: :primary)
      end

      def nes_triangle_lines(row, details, width)
        [title("#{row.channel.label} · 32-step triangle (no volume control)"),
         line("Period #{details[:period]} · #{nes_pitch(row.channel)}"),
         line("Linear counter #{details[:linear]} of #{details[:linear_load]}#{' · held' if details[:held]}"),
         line(nes_length_text(row)), line(triangle_wave(width), color: :primary)]
      end

      def nes_noise_lines(row, details, width)
        channel = row.channel
        tone = details[:short] ? '93-step (metallic, pitched)' : '32767-step (hiss)'
        [title("#{channel.label} · #{tone} LFSR"),
         line("Period index #{details[:period_index]} · LFSR clock #{format_hz(details[:lfsr_hz])}" \
              "#{" · #{note_text(channel)}" if channel.pitch_hz}"),
         line("Volume #{details[:volume]}/15 now · #{nes_envelope_text(details)}"), line(nes_length_text(row)),
         line(noise_wave(details[:short] ? :periodic : :white, width), color: :primary)]
      end

      def nes_dmc_lines(row, details, width) = dmc_voice_lines(row.channel, details, width)

      def nes_pcm_lines(row, details, _width)
        [title("#{row.channel.label} · 8-bit PCM DAC"), line("Level #{details[:level]} of 255"),
         line('Played by writing samples to $5011', color: :text_muted)]
      end

      def vrc6_pulse_lines(row, details, width)
        duty = details[:duty_sixteenths]
        [title("#{row.channel.label} · #{details[:digitized] ? 'DAC mode' : "#{duty}/16 duty square"}"),
         line("Period #{details[:period]} · #{nes_pitch(row.channel)}"),
         line("Volume #{details[:volume]}/15 · #{details[:enabled] ? 'enabled' : 'disabled'}"),
         line((('▔' * duty) + ('▁' * (16 - duty))).*((width / 16) + 1)[0, width], color: :primary)]
      end

      def vrc6_saw_lines(row, details, width)
        [title("#{row.channel.label} · 7-step sawtooth"), line("Period #{details[:period]} · #{nes_pitch(row.channel)}"),
         line("Rate #{details[:rate]} (accumulator step; #{VRC6_SAW_FULL_RATE}+ clips) · " \
              "#{details[:enabled] ? 'enabled' : 'disabled'}"),
         line('▁▂▃▄▅▆▇'.*((width / 7) + 1)[0, width], color: :primary)]
      end

      def n163_wave_lines(row, details, _width)
        [title("#{row.channel.label} · #{details[:wave_length]}-step 4-bit wave#{' (disabled)' unless details[:enabled]}"),
         line("Frequency #{details[:freq]} · #{nes_pitch(row.channel)}"),
         line("Volume #{details[:volume]}/15 · wave at RAM nibble #{format('$%02X', details[:wave_address])}")]
      end

      def s5b_square_lines(row, details, width)
        [title("#{row.channel.label} · AY-style square"), line("Period #{details[:period]} · #{nes_pitch(row.channel)}"),
         line("Volume #{details[:envelope] ? 'envelope' : "#{details[:volume]}/15"} · " \
              "tone #{details[:tone] ? 'on' : 'off'} · noise #{details[:noise] ? 'on' : 'off'}"),
         line(square_wave(details[:period], width), color: :primary)]
      end

      def fds_wave_lines(row, details, _width)
        [title("#{row.channel.label} · 64-step 6-bit wave"), line("Frequency #{details[:freq]} · #{nes_pitch(row.channel)}"),
         line("Gain #{details[:gain]} (#{fds_envelope_text(details[:envelope])}) · " \
              "master #{details[:master_volume]}%#{' · halted' if details[:halted]}"),
         line("Modulator #{fds_mod_text(details)}")]
      end

      def dmc_voice_lines(channel, details, width)
        total = details[:sample_length]
        done = ((total - details[:bytes_left]).fdiv(total) * width).round.clamp(0, width)
        [title("#{channel.label} · 1-bit delta PCM#{' (looping)' if details[:loop]}"),
         line("Sample #{format('$%04X', details[:sample_address])}, #{total} bytes · " \
              "#{format_hz(details[:bit_rate])} (rate #{details[:rate_index]})"),
         line("Output level #{details[:level]}/127 · #{details[:bytes_left]} bytes left · " \
              "reading #{format('$%04X', details[:address])}"),
         line(('█' * done) + ('░' * (width - done)), color: :primary)]
      end

      # Channels with a picture for the detail column; the others (a level
      # register and nothing more) give the column to the history.
      def nes_detail?(channel) = %i[nes_pulse nes_noise nes_triangle vrc6_saw n163_wave fds_wave].include?(channel.kind)

      # Pulse and noise: the volume envelope since the trigger, with a marker
      # at the time being heard. Wavetables: the wave. Others: their shape.
      def nes_detail_panel(row, width, rows)
        channel = row.channel
        details = channel.details
        case channel.kind
        when :nes_pulse, :nes_noise then nes_envelope_panel(row, width, rows)
        when :n163_wave then sample_panel('Wave RAM', details[:samples], 15, width, rows)
        when :fds_wave
          sample_panel('Wave', details[:samples], 63, width, rows - 1) <<
            line("Mod #{details[:mod_table].map { |step| '0124C#ED'[step] }.join}"[0, width], color: :text_muted)
        when :nes_triangle then shape_panel('Triangle (fixed shape)', triangle_samples, width, rows)
        when :vrc6_saw then shape_panel('Sawtooth (fixed shape)', Array.new(7) { |step| step * details[:rate] }, width, rows)
        else [title('Waveform'), line(NES_NO_DETAIL.fetch(channel.kind), color: :text_muted)]
        end
      end

      def nes_envelope_panel(row, width, rows)
        details = row.channel.details
        quarter_frame_hz = nes_quarter_frame_hz
        elapsed_seconds = seconds_since_trigger(row.channel)
        cutoff_seconds = nes_cutoff_seconds(details, quarter_frame_hz, elapsed_seconds)
        summary = "#{nes_envelope_text(details)}#{format(' · cut at %d ms', cutoff_seconds * 1000) if cutoff_seconds}"
        envelope_chart(summary: summary, span_seconds: nes_envelope_span(details, quarter_frame_hz, cutoff_seconds),
                       elapsed_seconds: elapsed_seconds, width: width, rows: rows) do |seconds|
          nes_envelope_volume(details, seconds, quarter_frame_hz, cutoff_seconds)
        end
      end

      # When the length counter silences the note, in seconds after the
      # trigger; nil while it is halted. It counts down at half the
      # quarter-frame rate, hence the factor of 2.
      def nes_cutoff_seconds(details, quarter_frame_hz, elapsed_seconds)
        return if details[:loop] || details[:length].to_i.zero?

        remaining_length_seconds = details[:length] * 2 / quarter_frame_hz
        (elapsed_seconds || 0) + remaining_length_seconds
      end

      def nes_envelope_volume(details, seconds, quarter_frame_hz, cutoff_seconds)
        return 0 if cutoff_seconds && seconds >= cutoff_seconds
        return details[:envelope_period] if details[:constant]

        steps = (seconds * quarter_frame_hz / (details[:envelope_period] + 1)).floor
        details[:loop] ? (15 - steps) % 16 : [15 - steps, 0].max
      end

      def nes_envelope_span(details, quarter_frame_hz, cutoff_seconds)
        decay = details[:constant] || details[:loop] ? nil : 16 * (details[:envelope_period] + 1) / quarter_frame_hz
        envelope_span_seconds([decay, cutoff_seconds].compact.min || 0)
      end

      def nes_quarter_frame_hz
        apu = Array(@snapshot&.chips).find { |chip| chip.id.start_with?('2a03') }
        QUARTER_FRAME_HZ.fetch(apu&.details&.dig(:pal) ? :pal : :ntsc)
      end

      def sample_panel(heading, samples, max, width, rows)
        columns = [width / samples.size, 1].max
        [title("#{heading} · #{samples.size} steps × #{max.bit_length}-bit"),
         *graph(samples.flat_map { |sample| Array.new(columns, sample) }, max, (rows - 1).clamp(1, NES_GRAPH_ROWS))]
      end

      def shape_panel(heading, samples, width, rows)
        sample_panel(heading, samples, [samples.max, 1].max, width, rows)
      end

      def triangle_samples = [*15.downto(0), *0..15]

      def triangle_wave(width) = '▇▆▅▄▃▂▁▁▂▃▄▅▆▇'.*((width / 14) + 1)[0, width]

      # Samples as one bar glyph each (pairs averaged past 16), so the shape
      # reads as one line.
      def sample_sparkline(samples, max)
        group = [samples.size / 16, 1].max
        samples.each_slice(group).map { |slice| LiveGlyphs::LEVEL_GLYPHS[1 + (slice.sum * 7 / (max * slice.size))] }.join
      end

      def nes_duty(details) = "#{details[:duty].to_s.delete_suffix('.0')}%"

      # Constant volume, or the decay: one step down every period+1 quarter
      # frames (~240 Hz NTSC), looping from 15 when bit 5 is set.
      def nes_envelope_text(details)
        return "constant vol #{details[:envelope_period]}" if details[:constant]

        "env 15 ↓ every #{details[:envelope_period] + 1}/240 s#{' looping' if details[:loop]}"
      end

      def nes_envelope_short(details)
        details[:constant] ? "vol #{details[:envelope_period]}" : "env ↓#{details[:envelope_period]}#{'∞' if details[:loop]}"
      end

      def nes_length_text(row)
        details = row.channel.details
        return 'Length counter halted (sounds until stopped)' if details[:loop] || details[:held]

        format('Length %d ms left', details[:length] * 2000 / nes_quarter_frame_hz)
      end

      # The squares' pitch sweep, or nil when off.
      def nes_sweep_text(details)
        return unless details[:sweep_enabled] && details[:sweep_shift].to_i.positive?

        format('sweep %s every %d/120 s, shift %d', details[:sweep_down] ? '↑ pitch' : '↓ pitch',
               details[:sweep_period] + 1, details[:sweep_shift])
      end

      def fds_envelope_text(envelope)
        return 'held' if envelope[:mode] == :held

        "ramping #{envelope[:mode]} at speed #{envelope[:speed]}"
      end

      def fds_mod_text(details)
        return 'mod off' unless details[:mod_enabled] && details[:mod_depth].positive?

        "mod #{format_hz(details[:mod_hz])} depth #{details[:mod_depth]}"
      end
    end
  end
end
