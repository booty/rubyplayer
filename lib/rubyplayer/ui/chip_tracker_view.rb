# frozen_string_literal: true

require_relative '../vgm/note_log'
require_relative '../vgm/pitch'
require_relative 'chip_live_view'

module RubyPlayer
  module UI
    # A tracker-shaped time grid built from a snapshot's note events (VGM, or
    # a native chip such as HES). The music has sample timing but no pattern
    # rows, so the rows are fixed 50 ms slices of the track.
    class ChipTrackerView
      ROW_SAMPLES = Vgm::SAMPLE_RATE / 20
      HEADER_ROWS = 3
      GUTTER_WIDTH_CELLS = 8
      COLUMN_WIDTH_CELLS = 11
      # Starts without a pitch, by channel kind; other kinds stream samples.
      UNPITCHED_LABELS = { noise: 'NOI', huc_noise: 'NOI', huc_dda: 'DAC' }.freeze
      Channel = Data.define(:chip_id, :chip_name, :voice_index, :label, :kind)
      private_constant :ROW_SAMPLES, :HEADER_ROWS, :GUTTER_WIDTH_CELLS, :COLUMN_WIDTH_CELLS,
                       :UNPITCHED_LABELS, :Channel

      attr_reader :snapshot

      # `source` names the format in the title (VGM, HES).
      def initialize(source: 'VGM')
        @source = source
        reset
      end

      def update(snapshot)
        identity = [snapshot&.generation, snapshot&.revision]
        reset if snapshot.nil? || (@identity && identity != @identity)
        @identity = identity if snapshot
        @snapshot = snapshot
        return self unless snapshot

        @channels = ChipLiveView.ordered_chips(snapshot.chips).flat_map do |chip|
          chip.channels.each_with_index.map do |channel, voice_index|
            Channel.new(chip_id: chip.id, chip_name: chip.name, voice_index: voice_index,
                        label: channel.label, kind: channel.kind)
          end
        end
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
      # `position_ms` is the track position, when now_sample counts something
      # else (native chips: output frames since launch).
      # rubocop:disable Naming/MethodParameterName
      def render(screen, x:, y:, width:, height:, theme:, track_title:, now_sample:, position_ms: nil)
        return if width <= 0 || height <= 0

        latch_track_offset(now_sample, position_ms)

        # Decoded here, not in update: App feeds both VGM pages every
        # snapshot, and only the page on screen needs its note history.
        @snapshot&.chips&.each { |chip| decode_events(chip) }
        visible_count = if @channels.empty?
                          0
                        else
                          ((width - GUTTER_WIDTH_CELLS) / COLUMN_WIDTH_CELLS).clamp(1, @channels.size)
                        end
        adjust_window(visible_count)
        elapsed_sample = (now_sample || @snapshot&.sample || 0) + @track_offset_sample.to_i
        current_bucket = [elapsed_sample, 0].max / ROW_SAMPLES
        status = @snapshot&.message || (@snapshot ? status_label : 'Loading')
        range = if @channels.empty?
                  ''
                else
                  "#{@window_index + 1}-#{@window_index + visible_count}/#{@channels.size}"
                end
        title = "#{track_title} · #{@source} TRACKER · #{format_time(current_bucket)}"
        title += " · #{status}" if status
        put(screen, x, y, width, height, 0, 0, title, fg: theme[:accent], bold: true)
        put(screen, x, y, width, height, 0, width - range.length, range, fg: theme[:text_muted]) unless range.empty?
        return if height <= HEADER_ROWS

        draw_headers(screen, x, y, width, height, theme, visible_count)
        draw_rows(screen, x, y, width, height, theme, current_bucket, visible_count)
      end

      private

      def reset
        @snapshot = nil
        @identity = nil
        @channels = []
        @packed_by_chip = {}
        @cells_by_chip = {}
        @track_offset_sample = nil
        @selected_index = 0
        @window_index = 0
      end

      # Event samples plus this offset are track samples. The offset holds
      # until the next reset (a seek starts a new generation), so millisecond
      # rounding in later positions cannot shift notes between rows.
      def latch_track_offset(now_sample, position_ms)
        return if @track_offset_sample || @snapshot.nil?

        @track_offset_sample = position_ms && now_sample ? (position_ms * Vgm::SAMPLE_RATE / 1000) - now_sample : 0
      end

      def status_label
        return if @snapshot.status == :ready

        @snapshot.status.to_s.capitalize
      end

      def decode_events(chip)
        packed = chip.details[:events]
        return if packed == @packed_by_chip[chip.id]

        @packed_by_chip[chip.id] = packed
        # No default proc: render's dig must not add empty rows for silent voices.
        cells = {}
        Vgm::NoteLog.decode(packed).each do |event|
          bucket = (event.sample + @track_offset_sample) / ROW_SAMPLES
          cell = ((cells[event.channel] ||= {})[bucket] ||= {})
          # A start and a later glide in one row both show (C-4>D-4); a
          # newer start replaces both, since the earlier note has ended.
          case event.kind
          when :on
            cell[:start] = event.midi ? pitch_label(event.midi) : unpitched_label(chip, event.channel)
            cell[:glide] = nil
            cell[:released] = false
          when :note
            cell[:glide] = ">#{pitch_label(event.midi)}"
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
        UNPITCHED_LABELS.fetch(chip.channels[voice_index]&.kind, 'PCM')
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

      def draw_rows(screen, x, y, width, height, theme, current_bucket, visible_count)
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

        label = "#{cell[:start]}#{cell[:glide]}"
        return '===' if label.empty?

        cell[:released] ? "#{label}!" : label
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
