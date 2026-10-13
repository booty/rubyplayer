# frozen_string_literal: true

require_relative '../vgm/note_log'
require_relative '../vgm/pitch'

module RubyPlayer
  module UI
    # A tracker-shaped time grid built from VGM note events. VGM commands have
    # sample timing but no pattern rows, so the rows are fixed 50 ms slices.
    class VgmTrackerView
      ROW_SAMPLES = Vgm::SAMPLE_RATE / 20
      HEADER_ROWS = 3
      GUTTER_WIDTH_CELLS = 8
      COLUMN_WIDTH_CELLS = 11
      CHIP_ORDER = { 'ym2612' => 0, 'sn76489' => 1, 'ym2413' => 2 }.freeze
      Channel = Data.define(:chip_id, :chip_name, :voice_index, :label, :kind)
      private_constant :ROW_SAMPLES, :HEADER_ROWS, :GUTTER_WIDTH_CELLS, :COLUMN_WIDTH_CELLS,
                       :CHIP_ORDER, :Channel

      attr_reader :snapshot

      def initialize
        reset
      end

      def update(snapshot)
        identity = [snapshot&.generation, snapshot&.revision]
        reset if snapshot.nil? || (@identity && identity != @identity)
        @identity = identity if snapshot
        @snapshot = snapshot
        return self unless snapshot

        ordered_chips = snapshot.chips.sort_by { |chip| [CHIP_ORDER.fetch(chip.id.split(':').first, 3), chip.id] }
        @channels = ordered_chips.flat_map do |chip|
          chip.channels.each_with_index.map do |channel, voice_index|
            Channel.new(chip_id: chip.id, chip_name: chip.name, voice_index: voice_index,
                        label: channel.label, kind: channel.kind)
          end
        end
        snapshot.chips.each { |chip| decode_events(chip) }
        self
      end

      # rubocop:disable Naming/PredicateMethod
      def handle_key(key)
        return false if @channels.empty?

        next_index = case key.to_s.downcase
                     when 'left' then @selected_index - 1
                     when 'right' then @selected_index + 1
                     else return false
                     end
        @selected_index = next_index.clamp(0, @channels.size - 1)
        true
      end
      # rubocop:enable Naming/PredicateMethod

      # Screen uses short x/y coordinates as its drawing convention.
      # rubocop:disable Naming/MethodParameterName
      def render(screen, x:, y:, width:, height:, theme:, track_title:, now_sample:, paused:)
        return if width <= 0 || height <= 0

        visible_count = if @channels.empty?
                          0
                        else
                          ((width - GUTTER_WIDTH_CELLS) / COLUMN_WIDTH_CELLS).clamp(1, @channels.size)
                        end
        adjust_window(visible_count)
        elapsed_sample = now_sample || @snapshot&.sample || 0
        current_bucket = [elapsed_sample, 0].max / ROW_SAMPLES
        status = @snapshot&.message || (@snapshot ? status_label : 'Loading')
        range = if @channels.empty?
                  ''
                else
                  "#{@window_index + 1}-#{@window_index + visible_count}/#{@channels.size}"
                end
        title = "#{track_title} · VGM TRACKER · #{format_time(current_bucket)}"
        title += " · #{status}" if status
        put(screen, x, y, width, height, 0, 0, title, fg: theme[:accent], bold: true)
        put(screen, x, y, width, height, 0, width - range.length, range, fg: theme[:text_muted]) unless range.empty?
        return if height <= HEADER_ROWS

        draw_headers(screen, x, y, width, height, theme, visible_count)
        draw_rows(screen, x, y, width, height, theme, current_bucket, visible_count, paused)
      end

      private

      def reset
        @snapshot = nil
        @identity = nil
        @channels = []
        @packed_by_chip = {}
        @cells_by_chip = {}
        @selected_index = 0
        @window_index = 0
      end

      def status_label
        return if @snapshot.status == :ready

        @snapshot.status.to_s.capitalize
      end

      def decode_events(chip)
        packed = chip.details[:events]
        return if packed == @packed_by_chip[chip.id]

        @packed_by_chip[chip.id] = packed
        cells = Hash.new { |hash, key| hash[key] = {} }
        Vgm::NoteLog.decode(packed).each do |event|
          bucket = event.sample / ROW_SAMPLES
          cell = (cells[event.channel][bucket] ||= {})
          case event.kind
          when :on
            cell[:label] = event.midi ? pitch_label(event.midi) : unpitched_label(chip, event.channel)
            cell[:released] = false
          when :note
            cell[:label] = event.midi ? ">#{pitch_label(event.midi)}" : nil
            cell[:released] = false
          when :off
            cell[:released] = true
          end
        end
        @cells_by_chip[chip.id] = cells
      end

      def pitch_label(midi)
        name = Vgm::Pitch.note_name(midi)
        name.sub(/\A([A-G])(?=-?\d)/, '\\1-')
      end

      def unpitched_label(chip, voice_index)
        chip.channels[voice_index]&.kind == :noise ? 'NOI' : 'PCM'
      end

      def adjust_window(visible_count)
        return if visible_count.zero?

        @window_index = @selected_index if @selected_index < @window_index
        @window_index = @selected_index - visible_count + 1 if @selected_index >= @window_index + visible_count
        @window_index = @window_index.clamp(0, [@channels.size - visible_count, 0].max)
      end

      def draw_headers(screen, x, y, width, height, theme, visible_count)
        put(screen, x, y, width, height, 1, 0, 'Chip', fg: theme[:text_muted])
        put(screen, x, y, width, height, 2, 0, 'Time', fg: theme[:text_muted])
        @channels[@window_index, visible_count].each_with_index do |channel, offset|
          column = GUTTER_WIDTH_CELLS + (offset * COLUMN_WIDTH_CELLS)
          selected = @window_index + offset == @selected_index
          color = selected ? theme[:accent] : theme[:text_muted]
          put(screen, x, y, width, height, 1, column, channel.chip_name, fg: color, bold: selected)
          put(screen, x, y, width, height, 2, column, channel.label, fg: color, bold: selected)
        end
      end

      def draw_rows(screen, x, y, width, height, theme, current_bucket, visible_count, _paused)
        grid_rows = height - HEADER_ROWS
        current_row = [grid_rows - 2, 0].max
        first_bucket = current_bucket - current_row
        grid_rows.times do |index|
          bucket = first_bucket + index
          next if bucket.negative? || bucket > current_bucket

          row = HEADER_ROWS + index
          active = bucket == current_bucket
          foreground = active ? theme[:accent] : theme[:text_muted]
          put(screen, x, y, width, height, row, 0, format_time(bucket), fg: foreground, bold: active)
          @channels[@window_index, visible_count].each_with_index do |channel, offset|
            cell = @cells_by_chip.dig(channel.chip_id, channel.voice_index, bucket)
            column = GUTTER_WIDTH_CELLS + (offset * COLUMN_WIDTH_CELLS)
            put(screen, x, y, width, height, row, column, cell_text(cell),
                fg: active ? theme[:accent] : theme[:text], bold: active)
          end
        end
      end

      def cell_text(cell)
        return '...' unless cell
        return '===' unless cell[:label]

        cell[:released] ? "#{cell[:label]}!" : cell[:label]
      end

      def format_time(bucket)
        centiseconds = bucket * 5
        minutes, remainder = centiseconds.divmod(6_000)
        seconds, hundredths = remainder.divmod(100)
        format('%d:%02d.%02d', minutes, seconds, hundredths)
      end

      def put(screen, x, y, width, height, row, column, value, **style)
        return if row.negative? || row >= height || column >= width

        left = [column, 0].max
        length = width - left
        screen.put(y + row, x + left, value.to_s[left - column, length].to_s, **style)
      end
      # rubocop:enable Naming/MethodParameterName
    end
  end
end
