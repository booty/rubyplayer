# frozen_string_literal: true

require_relative '../vgm/snapshot'

module RubyPlayer
  module UI
    # Renders immutable VGM channel snapshots inside a caller-owned rectangle.
    class VgmChannels
      RECENT_TRIGGER_SAMPLES = 2_205
      OPERATOR_LABELS = {
        dt: 'DT', mul: 'MUL', tl: 'TL', rs: 'RS', ar: 'AR', am: 'AM',
        d1r: 'D1R', d2r: 'D2R', d1l: 'D1L', rr: 'RR', ssg_eg: 'SSG',
        pm: 'PM', eg: 'EG', ksr: 'KSR', key_scale_level: 'KSL',
        total_level: 'TL', feedback: 'FB', waveform: 'WAV', dr: 'DR', sl: 'SL'
      }.freeze
      CHIP_DETAIL_FIELDS = %i[variant dac_enabled csm_enabled rhythm_mode lfo_enabled
                              noise_feedback shift_width flags stereo_register].freeze
      CHIP_ORDER = { 'ym2612' => 0, 'sn76489' => 1, 'ym2413' => 2 }.freeze
      PAN_LABELS = { lr: 'L/R', l: 'L', r: 'R', none: '--' }.freeze
      # Key handling can arrive before the first render records real
      # dimensions; assume a typical full-size modal until then.
      FALLBACK_WIDTH = 100
      FALLBACK_HEIGHT = 28
      private_constant :RECENT_TRIGGER_SAMPLES, :OPERATOR_LABELS,
                       :CHIP_DETAIL_FIELDS, :CHIP_ORDER, :PAN_LABELS,
                       :FALLBACK_WIDTH, :FALLBACK_HEIGHT

      attr_reader :selected_channel_id, :snapshot
      attr_accessor :paused

      def initialize
        @snapshot = nil
        @channels = []
        @selected_channel_id = nil
        @selected_index = 0
        @scroll = 0
        @detail_page = :patch
        @detail_page_index = 0
        @paused = false
        @last_generation = nil
      end

      def update(snapshot)
        previous_id = @selected_channel_id
        new_source = snapshot && snapshot.generation != @last_generation
        if new_source
          @selected_index = 0
          @scroll = 0
          @detail_page = :patch
          @detail_page_index = 0
          previous_id = nil
        end
        @last_generation = snapshot.generation if snapshot
        @snapshot = snapshot
        @channels = Array(snapshot&.chips).sort_by { |chip| chip_order(chip) }.flat_map do |chip|
          chip.channels.map { |channel| [chip, channel] }
        end
        return self unless snapshot

        selected = @channels.index { |_chip, channel| channel.id == previous_id }
        @selected_index = selected || 0
        @selected_channel_id = @channels.dig(@selected_index, 1)&.id
        self
      end

      # Key handling returns whether this widget consumed the command.
      # rubocop:disable Naming/PredicateMethod
      def handle_key(key)
        return false if @channels.empty?

        case key.to_s.downcase
        when 'up'
          select(@selected_index - 1)
        when 'down'
          select(@selected_index + 1)
        when 'pageup'
          select(@selected_index - [@visible_rows || 1, 1].max)
        when 'pagedown'
          select(@selected_index + [@visible_rows || 1, 1].max)
        when 'left', 'right'
          return false unless cycle_detail?(key.to_s.downcase == 'right' ? 1 : -1)
        else
          return false
        end
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Screen rectangle coordinates use the Screen API's short x/y names.
      # rubocop:disable Naming/MethodParameterName
      def render(screen, x:, y:, width:, height:, theme:)
        return if width <= 0 || height <= 0

        @last_width = width
        @last_height = height
        sample = @snapshot&.sample || 0
        status = @snapshot&.status || :loading
        header_rows = height >= 4 ? 1 : 0
        detail_rows = detail_capacity(height)
        @visible_rows = [height - 1 - header_rows - detail_rows, 0].max
        channel_start = y + 1 + header_rows

        render_header(screen, x, y, width, sample, status, theme)
        if @channels.empty?
          render_empty(screen, x, y, width, height, status, theme)
          return
        end

        render_column_heading(screen, x, y, width, header_rows, theme)
        render_channels(screen, x, channel_start, width, sample, theme)
        render_details(screen, x, y, width, height, detail_rows, theme)
      end
      # rubocop:enable Naming/MethodParameterName

      private

      def render_header(screen, column, row, width, sample, status, theme)
        loop_count = @snapshot&.loop_count || 0
        playback = if @paused
                     'PAUSED'
                   elsif width < 72
                     'PLAY'
                   else
                     'PLAYING'
                   end
        header = if width < 72
                   "LIVE #{status.to_s.upcase} #{format_time(sample)} L#{loop_count} #{playback}"
                 else
                   "Live channels · #{status.to_s.upcase} · #{format_time(sample)} · " \
                     "Loop #{loop_count} · #{playback}"
                 end
        put(screen, row, column, width, header, fg: theme[:accent], bold: true)
      end

      def detail_capacity(height)
        header_rows = height >= 4 ? 1 : 0
        available = height - header_rows - 2
        return 0 if available <= 0

        desired = height < 10 ? height / 2 : (height / 4).clamp(1, 5)
        [desired, available].min
      end

      def render_column_heading(screen, column, row, width, header_rows, theme)
        return unless header_rows.positive?

        heading = if width < 48
                    'Channel  State   Pitch'
                  elsif width < 72
                    'Channel       State       Pitch        Patch'
                  else
                    'Channel       State       Pitch        Patch        Pan'
                  end
        put(screen, row + 1, column, width, heading, fg: theme[:text_muted], bold: true)
      end

      def render_empty(screen, column, row, width, height, status, theme)
        messages = empty_messages
        messages = [status_message(status)] if messages.empty?
        messages.first([height - 1, 0].max).each_with_index do |message, index|
          put(screen, row + 1 + index, column, width, message, fg: status_color(status, theme))
        end
      end

      def render_channels(screen, column, channel_start, width, sample, theme)
        adjust_scroll
        @visible_rows.times do |row|
          index = @scroll + row
          break if index >= @channels.size

          _chip, channel = @channels[index]
          selected = index == @selected_index
          text = channel_line(channel, sample, width, selected)
          put(screen, channel_start + row, column, width, text,
              fg: selected ? theme[:selection_text] : row_color(channel, theme),
              bg: selected ? theme[:selection_bg] : nil, bold: selected || active?(channel, sample))
        end
      end

      def render_details(screen, column, row, width, height, detail_rows, theme)
        detail_start = row + height - detail_rows
        detail_lines(detail_rows, width).each_with_index do |line, index|
          put(screen, detail_start + index, column, width, line,
              fg: index.zero? ? theme[:accent] : theme[:text_muted], bold: index.zero?)
        end
      end

      def chip_order(chip)
        [CHIP_ORDER.fetch(chip.id.split(':').first, 3), chip.id]
      end

      def select(index)
        @selected_index = index.clamp(0, @channels.size - 1)
        @selected_channel_id = @channels[@selected_index][1].id
        @detail_page = :patch
        @detail_page_index = 0
      end

      def cycle_detail?(direction)
        maximum = detail_capacity(@last_height || FALLBACK_HEIGHT)
        pages = detail_pages(maximum, @last_width || FALLBACK_WIDTH)
        return false if pages.empty?

        index = pages.index { |page, page_index, _lines| [page, page_index] == [@detail_page, @detail_page_index] } || 0
        @detail_page, @detail_page_index = pages[(index + direction) % pages.size].first(2)
        true
      end

      def adjust_scroll
        return if @visible_rows >= @channels.size

        @scroll = @selected_index if @selected_index < @scroll
        @scroll = @selected_index - @visible_rows + 1 if @selected_index >= @scroll + @visible_rows
        @scroll = @scroll.clamp(0, @channels.size - @visible_rows)
      end

      def channel_line(channel, sample, width, selected)
        marker = recent?(channel, sample) ? '*' : ' '
        prefix = selected ? '>' : ' '
        prefix = "#{prefix}#{marker} "
        state = channel.state.to_s.upcase.tr('_', ' ')
        pitch = channel.note.to_s
        pitch = '--' if pitch.empty?
        if width < 48
          "#{prefix}#{channel.label} #{state} #{pitch}"
        elsif width < 72
          signature = channel.patch&.digest&.[](0, 6) || channel.details[:fm_patch]&.digest&.[](0, 6) || '--'
          prefix + format('%-13s %-11s %-12s %s', channel.label, state, pitch, signature)[0, width - prefix.length]
        else
          signature = channel.patch&.digest&.[](0, 12) || channel.details[:fm_patch]&.digest&.[](0, 12) || '--'
          pan = format_pan(channel.pan)
          full = format('%-13s %-11s %-12s %-12s %s', channel.label, state, pitch, signature, pan)
          prefix + full[0, width - prefix.length]
        end
      end

      def detail_lines(maximum, width)
        return [] if maximum <= 0 || @channels.empty?

        pages = detail_pages(maximum, width)
        page = pages.find do |kind, index, _lines|
          [kind, index] == [@detail_page, @detail_page_index]
        end
        unless page
          page = pages.first
          @detail_page, @detail_page_index = page.first(2)
        end
        page.last
      end

      def detail_pages(maximum, width)
        return [] if maximum <= 0 || @channels.empty?

        chip, channel = @channels.fetch(@selected_index)
        pages = []
        patch_detail_groups(channel, maximum, width).each_with_index do |lines, index|
          pages << [:patch, index, lines]
        end
        channel_detail_lines(channel, width).each_slice(maximum).with_index do |lines, index|
          pages << [:channel, index, lines]
        end
        chip_detail_lines(chip, width).each_slice(maximum).with_index do |lines, index|
          pages << [:chip, index, lines]
        end
        pages
      end

      def patch_detail_groups(channel, maximum, width)
        patch = channel.patch || channel.details[:fm_patch]
        return channel_patch_lines(channel, width).each_slice(maximum).to_a if patch.nil?

        alg = patch.algorithm.nil? ? '--' : patch.algorithm
        feedback = patch.feedback.nil? ? '--' : patch.feedback
        heading = "Patch · ALG #{alg} · FB #{feedback}"
        operators = patch.operators
        return [[heading]] if operators.empty?

        compact = width < 72 || (@last_height || FALLBACK_HEIGHT) < 20
        if compact
          operators.flat_map do |operator|
            operator_lines(operator, width).each_slice([maximum - 1, 1].max).map do |lines|
              if maximum > 1
                ["#{heading} · OP #{operator.index}", *lines]
              else
                lines
              end
            end
          end
        else
          lines = [heading]
          operators.each { |operator| lines.concat(operator_lines(operator, width)) }
          lines.each_slice(maximum).to_a
        end
      end

      def operator_lines(operator, width)
        operator.parameters.each_with_object([format('OP %d', operator.index)]) do |(key, value), lines|
          label = OPERATOR_LABELS.fetch(key, key.to_s.upcase)
          field = "#{label} #{value.nil? ? '--' : value}"
          if lines.last.length + field.length + 1 <= width
            lines[-1] = "#{lines.last} #{field}"
          else
            lines << "OP #{operator.index}+ #{field}"
          end
        end
      end

      def channel_patch_lines(channel, width)
        details = channel.details
        lines = case channel.kind
                when :tone
                  if details.key?(:period)
                    ["#{channel.label} · tone period #{details[:period] || '--'}",
                     "Pitch #{channel.note || '--'} · attenuation #{details[:attenuation] || '--'}",
                     "Period #{details[:period] || '--'} · route #{format_pan(channel.pan)}"]
                  else
                    ["#{channel.label} · program #{details[:program_number] || '--'}",
                     "Volume #{details[:volume] || '--'} · FNUM #{details[:fnum] || '--'}",
                     format('Block %s · key %s · sustain %s', details[:block] || '--',
                            details[:key_on] || false, details[:sustain] || false)]
                  end
                when :noise
                  ["Noise · #{details[:noise_type] || '--'} · #{details[:noise_rate] || '--'}",
                   "Tone-3 coupled #{details[:tone_3_coupled] || false} · route #{format_pan(channel.pan)}",
                   "Attenuation #{details[:attenuation] || '--'}"]
                when :percussion
                  ["#{channel.label} · rhythm percussion",
                   "Roles #{Array(details[:roles]).join(', ')} · keys #{details[:percussion_keys] || '--'}"]
                else
                  ['Patch unavailable']
                end
        wrap_lines(lines, width)
      end

      def channel_detail_lines(channel, width)
        details = channel.details
        lines = ["#{channel.label}: #{channel.state.to_s.upcase.tr('_', ' ')} · #{channel.note || '--'}"]
        lines << "Pan #{format_pan(channel.pan)} · Trigger sample #{channel.last_trigger_sample || '--'}"
        append_frequency_details(lines, details)
        append_key_details(lines, details)
        append_special_frequency_details(lines, details)
        append_dac_details(lines, details)
        append_program_details(lines, details)
        append_attenuation_details(lines, channel, details)
        append_csm_warning(lines, details)
        wrap_lines(lines, width)
      end

      def append_frequency_details(lines, details)
        frequency = details[:frequency]
        lines << "FNUM #{frequency[:fnum]} · block #{frequency[:block]}" if frequency
      end

      def append_key_details(lines, details)
        if %i[algorithm feedback key_mask].any? { |key| details.key?(key) }
          lines << format('Algorithm %s · Feedback %s · Keys %s',
                          details[:algorithm] || '--', details[:feedback] || '--',
                          details[:key_mask] || '--')
        end
        lines << "AMS #{details[:ams]} · FMS #{details[:fms]}" if details.key?(:ams) || details.key?(:fms)
      end

      def append_special_frequency_details(lines, details)
        Array(details[:special_frequencies]).each do |frequency|
          hz = frequency[:pitch_hz] ? format('%.1f Hz', frequency[:pitch_hz]) : '--'
          fnum = frequency[:fnum] || '--'
          block = frequency[:block] || '--'
          lines << "Special OP #{frequency[:operator]} · FNUM #{fnum} · " \
                   "block #{block} · #{hz}"
        end
      end

      def append_dac_details(lines, details)
        return unless details.key?(:dac_enabled)

        lines << "DAC #{details[:dac_enabled] ? 'enabled' : 'disabled'} · " \
                 "byte #{details[:dac_value] || '--'} · sample #{details[:dac_sample] || '--'}"
      end

      def append_program_details(lines, details)
        return unless details.key?(:program_number)

        lines << "Program #{details[:program_number] || '--'} · volume #{details[:volume] || '--'}"
      end

      def append_attenuation_details(lines, channel, details)
        return unless details.key?(:attenuation)

        lines << "Attenuation #{details[:attenuation]} · route #{format_pan(channel.pan)}"
      end

      def append_csm_warning(lines, details)
        lines << 'CSM timer key activity is unmodeled' if details[:special_mode] || details[:csm_enabled]
      end

      def chip_detail_lines(chip, width)
        details = chip.details
        lines = ['Register activity; release tails and audio levels are not measured.',
                 "#{chip.name} · #{chip.clock_hz || '--'} Hz"]
        CHIP_DETAIL_FIELDS.each do |key|
          lines << "#{key.to_s.tr('_', ' ')}: #{details[key]}" unless details[key].nil?
        end
        if details.key?(:timer_a) || details.key?(:timer_b)
          lines << "Timer A #{details[:timer_a] || '--'} · Timer B #{details[:timer_b] || '--'}"
        end
        if details.key?(:dac_enabled) || details.key?(:dac_value)
          lines << "DAC byte #{details[:dac_value] || '--'} · last write sample #{details[:dac_sample] || '--'}"
        end
        lines << 'CSM timer key activity is unmodeled' if details[:timer_generated_key_activity] == :unmodeled
        message = details[:message]
        lines << message if message
        lines.concat(@snapshot.warnings.map { |warning| "Warning: #{sanitize(warning)}" })
        wrap_lines(lines, width)
      end

      def wrap_lines(lines, width)
        lines.flat_map { |line| wrap_text(line, width) }
      end

      def wrap_text(text, width)
        words = sanitize(text).split(/\s+/)
        lines = []
        current = +''
        words.each do |word|
          if current.empty?
            current = word
          elsif current.length + word.length + 1 <= width
            current = "#{current} #{word}"
          else
            lines << current
            current = word
          end
        end
        lines << current unless current.empty?
        lines
      end

      def empty_messages
        return [] unless @snapshot

        messages = []
        messages << @snapshot.message if @snapshot.message
        messages.concat(@snapshot.warnings)
        @snapshot.chips.each do |chip|
          messages << chip.details[:message] if chip.details[:message]
        end
        messages.map { |message| sanitize(message) }.uniq
      end

      def status_message(status)
        {
          loading: 'Waiting for VGM telemetry', ready: 'No channel state available',
          partial: 'Partial register information', unsupported: 'Live detail unsupported',
          error: 'Unable to read VGM telemetry', ended: 'VGM playback ended'
        }.fetch(status, 'No live channel data')
      end

      def status_color(status, theme)
        %i[error unsupported].include?(status) ? theme[:warning] : theme[:text_muted]
      end

      def row_color(channel, theme)
        %i[muted key_off].include?(channel.state) ? theme[:text_muted] : theme[:text]
      end

      def active?(channel, sample)
        channel.state == :key_on || channel.state == :enabled || recent?(channel, sample)
      end

      def recent?(channel, sample)
        channel.last_trigger_sample && sample >= channel.last_trigger_sample &&
          sample - channel.last_trigger_sample <= RECENT_TRIGGER_SAMPLES
      end

      def format_pan(pan)
        PAN_LABELS.fetch(pan, pan.to_s.upcase)
      end

      def format_time(sample)
        seconds = sample.to_i / Vgm::SAMPLE_RATE
        format('%d:%02d', seconds / 60, seconds % 60)
      end

      def sanitize(value)
        value.to_s.gsub(/[[:cntrl:]]/, ' ').strip
      end

      def put(screen, row, column, width, text, **style)
        screen.put(row, column, sanitize(text)[0, width], **style)
      end
    end
  end
end
