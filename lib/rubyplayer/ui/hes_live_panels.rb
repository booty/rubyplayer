# frozen_string_literal: true

module RubyPlayer
  module UI
    # HuC6280 PSG parts of ChipLiveView (HES tracks): the chip line,
    # instrument text, levels, and voice and wave panels. Registers are read
    # from the emulator, but the level bar shows libgme's output gain, not
    # the sound (the wave or DAC sample also shapes it), so it is labeled an
    # estimate. The PSG has no envelope generator, and libgme plays neither
    # its LFO nor the CD-ROM ADPCM voice, so neither is drawn. Relies on
    # ChipLiveView's line/title/fit/format helpers.
    module HesLivePanels
      HES_KINDS = %i[huc_wave huc_noise huc_dda].freeze
      # Hes_Osc::amp_range: the gain at full volume and balance.
      FULL_GAIN = 0x8000
      MAX_VOLUME = 31
      MAX_SAMPLE = 31

      private

      def hes_summary(chip)
        details = chip.details
        [chip.name, format_clock(chip.clock_hz), "master L#{details[:master_left]} R#{details[:master_right]}",
         format('VBlank %.1f Hz', details[:vblank_hz])].join(' · ')
      end

      def hes_instrument_texts(channel)
        details = channel.details
        volume = "vol #{details[:volume]}"
        case channel.kind
        when :huc_wave
          wave = sample_sparkline(details[:samples], MAX_SAMPLE)
          ["wave #{wave} · #{volume} · #{balance_text(details)}", "wave #{wave} · #{volume}", "#{wave} v#{details[:volume]}"]
        when :huc_noise
          ["noise · LFSR #{format_hz(details[:noise_lfsr_hz])} · #{volume}", "noise · #{volume}",
           "noise v#{details[:volume]}"]
        else
          sample = format('$%02X', details[:dac_sample])
          ["direct DAC · sample #{sample} · #{volume}", "DAC #{sample} · #{volume}", "DAC v#{details[:volume]}"]
        end
      end

      # The louder side's gain, as an attenuation like the other chips'.
      def hes_attenuation(channel)
        return Vgm::Envelope::MAX_ATTENUATION_STEPS unless channel.state == :enabled

        details = channel.details
        amplitude_attenuation([details[:gain_left], details[:gain_right]].max.fdiv(FULL_GAIN))
      end

      def hes_voice_lines(row, width)
        channel = row.channel
        details = channel.details
        [title("#{channel.label} · #{hes_mode_text(channel)}"), line(hes_source_line(channel)),
         line("Volume #{details[:volume]}/#{MAX_VOLUME} · #{balance_text(details)} · gain #{gain_text(details)}"),
         line("Key #{details[:key_on] ? 'on' : 'off'} · #{hes_mode_note(channel)}"[0, width], color: :text_muted)]
      end

      # Only a wave voice has a graph worth its own column; noise and DAC give
      # it to the history and draw a line under the voice panel instead.
      def hes_detail?(channel) = channel.kind == :huc_wave

      def hes_detail_panel(row, width, rows)
        details = row.channel.details
        case row.channel.kind
        when :huc_wave then wave_ram_panel(details[:samples], MAX_SAMPLE, width, rows)
        when :huc_noise then [title('Noise LFSR'), line(noise_wave(:white, width), color: :primary)]
        else [title('Direct DAC sample'), line(level_bar(details[:dac_sample], MAX_SAMPLE, width), color: :primary)]
        end
      end

      def hes_mode_text(channel)
        case channel.kind
        when :huc_wave then '32-step 5-bit wave'
        when :huc_noise then 'noise'
        else 'direct DAC'
        end
      end

      def hes_source_line(channel)
        details = channel.details
        pan = "pan #{pan_label(channel)}"
        case channel.kind
        when :huc_wave
          hz = channel.pitch_hz ? format_hz(channel.pitch_hz) : '--'
          "Period #{details[:period_register]} · #{hz} · #{note_text(channel)} · #{pan}"
        when :huc_noise
          "Noise rate #{details[:noise_rate_code]} · LFSR clock #{format_hz(details[:noise_lfsr_hz])} · #{pan}"
        else
          "DAC sample #{format('$%02X', details[:dac_sample])} (#{details[:dac_sample]}/#{MAX_SAMPLE}) · #{pan}"
        end
      end

      # Why noise and DAC voices show no note.
      def hes_mode_note(channel)
        case channel.kind
        when :huc_wave then 'pitch from the wave period'
        when :huc_noise then 'noise has no pitch'
        else 'the driver streams samples; no pitch'
        end
      end

      def balance_text(details) = "bal L#{details[:balance_left]} R#{details[:balance_right]}"

      def gain_text(details)
        left, right = details.values_at(:gain_left, :gain_right).map { |gain| (gain * 100).fdiv(FULL_GAIN).round }
        "L#{left}% R#{right}%"
      end
    end
  end
end
