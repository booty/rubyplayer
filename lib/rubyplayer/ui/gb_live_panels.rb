# frozen_string_literal: true

module RubyPlayer
  module UI
    # Game Boy APU parts of ChipLiveView (GBS tracks): the chip line,
    # instrument text, levels, and voice and envelope panels. Unlike FM, the
    # APU's state is read from the emulator, so levels and envelopes are
    # exact. Relies on ChipLiveView's line/title/fit/format helpers.
    module GbLivePanels
      GB_KINDS = %i[gb_pulse gb_wave gb_noise].freeze
      # Duty cycles as one 8-step period of the square wave.
      DUTY_WAVES = { 12.5 => '▔▁▁▁▁▁▁▁', 25 => '▔▔▁▁▁▁▁▁', 50 => '▔▔▔▔▁▁▁▁', 75 => '▔▔▔▔▔▔▁▁' }.freeze
      MAX_GRAPH_ROWS = 8

      private

      def gb_kind?(channel) = GB_KINDS.include?(channel.kind)

      def gb_summary(chip)
        details = chip.details
        driver = details[:driver_hz] ? format('driver %.1f Hz', details[:driver_hz]) : 'driver --'
        driver += details[:vblank_driver] ? ' (VBlank)' : ' (timer)'
        [chip.name, format_clock(chip.clock_hz), "power #{details[:power] ? 'on' : 'off'}",
         "master L#{details[:master_left]} R#{details[:master_right]}", driver].join(' · ')
      end

      def gb_instrument_texts(channel)
        details = channel.details
        case channel.kind
        when :gb_pulse
          duty = "#{duty_text(details)} duty"
          sweep = sweep_text(details)
          ["#{duty} · #{envelope_text(details)}#{" · #{sweep}" if sweep}", "#{duty} · #{envelope_text(details)}",
           "#{duty} · #{env_short(details)}", "#{duty_text(details)} #{env_short(details)}"]
        when :gb_wave
          ["wave #{wave_sparkline(details)} · output #{details[:level]}%", "#{wave_sparkline(details)} #{details[:level]}%"]
        else
          noise = "#{details[:width]}-bit noise"
          ["#{noise} · #{format_hz(details[:lfsr_hz])} · #{envelope_text(details)}", "#{noise} · #{env_short(details)}",
           "#{details[:width]}-bit #{env_short(details)}"]
        end
      end

      # The volume being output, as an attenuation like the other chips'.
      def gb_attenuation(channel)
        return Vgm::Envelope::MAX_ATTENUATION unless channel.state == :enabled

        details = channel.details
        amplitude = channel.kind == :gb_wave ? details[:level] / 100.0 : details[:volume] / 15.0
        return Vgm::Envelope::MAX_ATTENUATION unless amplitude.positive?

        (-20 * Math.log10(amplitude) / Vgm::Envelope::DB_PER_STEP).round
      end

      def gb_voice_lines(row, width)
        channel = row.channel
        details = channel.details
        pitch = "Period #{details[:frequency]} · #{channel.pitch_hz ? format_hz(channel.pitch_hz) : '--'} · " \
                "#{note_text(channel)} · pan #{pan_label(channel)}"
        case channel.kind
        when :gb_pulse
          lines = [title("#{channel.label} · #{duty_text(details)} duty square"), line(pitch), volume_line(details),
                   line(length_text(details))]
          if details.key?(:sweep_pace)
            sweep = sweep_text(details)
            text = sweep ? "Sweep #{sweep.delete_prefix('sweep ')} · shadow period #{details[:sweep_freq]}" : 'Sweep off'
            lines << line(text)
          end
          lines << line(DUTY_WAVES.fetch(details[:duty]).*((width / 8) + 1)[0, width], color: :primary)
        when :gb_wave
          [title("#{channel.label} · 32-step 4-bit wave · output #{details[:level]}%"), line(pitch),
           line("DAC #{details[:dac] ? 'on' : 'off'} · #{length_text(details)}")]
        else
          tone = details[:width] == 7 ? 'metallic, pitched' : 'hiss'
          [title("#{channel.label} · #{details[:width]}-bit LFSR (#{tone})"),
           line("LFSR clock #{format_hz(details[:lfsr_hz])} · shift #{details[:clock_shift]} · " \
                "divisor #{details[:divisor]}#{" · #{note_text(channel)}" if channel.pitch_hz}"),
           volume_line(details), line(length_text(details)),
           line(noise_wave(details[:width] == 7 ? :periodic : :white, width), color: :primary)]
        end
      end

      # Pulse and noise: the exact volume envelope from the last trigger, with
      # a marker at the time being heard. Wave: the wave RAM.
      def gb_envelope_panel(row, width, rows)
        details = row.channel.details
        return wave_panel(details, width, rows) if row.channel.kind == :gb_wave

        envelope_chart(summary: envelope_summary(details), span_seconds: envelope_span(details),
                       elapsed_seconds: seconds_since_trigger(row.channel), width: width, rows: rows) do |seconds|
          envelope_volume(details, seconds)
        end
      end

      def wave_panel(details, width, rows)
        samples = details[:samples]
        columns = [width / samples.size, 1].max
        lines = [title('Wave RAM · 32 × 4-bit'),
                 *graph(samples.flat_map { |sample| Array.new(columns, sample) }, 15, (rows - 2).clamp(1, MAX_GRAPH_ROWS))]
        lines << line(samples.each_slice(2).map { |high, low| format('%X%X', high, low) }.join(' ')[0, width],
                      color: :text_muted)
      end

      def envelope_volume(details, seconds)
        cut = length_seconds(details)
        return 0 if cut && seconds >= cut

        pace = details[:envelope_pace]
        return details[:initial_volume] if pace.zero?

        steps = (seconds * 64 / pace).floor
        (details[:initial_volume] + (details[:envelope_up] ? steps : -steps)).clamp(0, 15)
      end

      def envelope_span(details)
        pace = details[:envelope_pace]
        steps = details[:envelope_up] ? 15 - details[:initial_volume] : details[:initial_volume]
        ends = [pace.zero? ? nil : steps * pace / 64.0, length_seconds(details)].compact
        envelope_span_seconds(ends.min || 0)
      end

      # Length counter load, in seconds, when the length counter is on.
      def length_seconds(details) = details[:length_enabled] ? details[:length_load] / 256.0 : nil

      def envelope_summary(details)
        cut = length_seconds(details)
        "#{envelope_text(details)}#{format(' · cut at %d ms', cut * 1000) if cut}"
      end

      # NRx2 as read: starting volume, then one step up or down every pace/64 s.
      def envelope_text(details)
        pace = details[:envelope_pace]
        return "env held at #{details[:initial_volume]}" if pace.zero?

        format('env %d %s every %.1f ms', details[:initial_volume], details[:envelope_up] ? '↑' : '↓',
               pace * 1000 / 64.0)
      end

      def env_short(details)
        pace = details[:envelope_pace]
        "env #{details[:initial_volume]}#{unless pace.zero?
                                            details[:envelope_up] ? '↑' : '↓'
                                          end}"
      end

      def volume_line(details)
        line("Volume #{details[:volume]}/15 now · #{envelope_text(details)}#{' · DAC off' unless details[:dac]}")
      end

      def length_text(details)
        return 'Length counter off (sounds until stopped)' unless details[:length_enabled]

        format('Length %d ms left of %d ms', details[:length] * 1000 / 256, details[:length_load] * 1000 / 256)
      end

      # Square 1's pitch sweep, or nil when off.
      def sweep_text(details)
        return if details[:sweep_pace].to_i.zero?

        format('sweep %s every %.1f ms, shift %d', details[:sweep_down] ? '↓' : '↑', details[:sweep_pace] * 1000 / 128.0,
               details[:sweep_shift])
      end

      def duty_text(details) = "#{details[:duty].to_s.delete_suffix('.0')}%"

      # The 32-sample wave as 16 bar glyphs (pairs averaged); silence is the
      # lowest bar, not a gap, so the shape reads as one line.
      def wave_sparkline(details)
        details[:samples].each_slice(2).map { |pair| LiveGlyphs::LEVEL_GLYPHS[1 + (pair.sum * 7 / 30)] }.join
      end
    end
  end
end
