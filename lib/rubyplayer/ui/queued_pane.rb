# frozen_string_literal: true

module RubyPlayer
  module UI
    # Read-only overview of upcoming playback and recent history.
    class QueuedPane
      HISTORY_LIMIT = 3
      # Upcoming's header and the selected track (or "Queue empty"). The pane
      # takes focus and track actions, so these outrank history for space.
      UPCOMING_MIN_ROWS = 2
      PreparedConfig = Data.define(:formatter, :star_glyph, :upcoming_rows, :previous_rows)
      private_constant :PreparedConfig

      attr_reader :upcoming, :previous

      def initialize(config:, upcoming_source:, history_source:)
        @upcoming_source = upcoming_source
        @history_source = history_source
        @selection = QueueSelection.new
        @upcoming = @upcoming_source.call.dup.freeze
        @total_duration = total_duration
        @selection.replace(@upcoming)
        @previous = @history_source.call.first(HISTORY_LIMIT).dup.freeze
        update_config(config)
      end

      def handle_action(action)
        @selection.handle_action(action)
      end

      def selected_track
        @selection.selected_track
      end

      def selected_tracks = @selection.selected_tracks

      def selected_track_index
        @selection.selected_index
      end

      def update_config(config)
        apply_config(prepare_config(config))
        nil
      end

      # Format every current row before publishing any config-derived state.
      # App uses this during hot reload so a bad callable cannot partially
      # activate the candidate config.
      def prepare_config(config)
        formatter = config['ui', 'format_track_queued']
        star_glyph = config['glyphs', 'star']
        PreparedConfig.new(
          formatter: formatter,
          star_glyph: star_glyph,
          upcoming_rows: build_rows(@upcoming, formatter:, star_glyph:, indexed: true),
          previous_rows: build_rows(@previous, formatter:, star_glyph:)
        )
      end

      def apply_config(prepared)
        @formatter = prepared.formatter
        @star_glyph = prepared.star_glyph
        @upcoming_rows = prepared.upcoming_rows
        @previous_rows = prepared.previous_rows
        nil
      end

      def reload!
        @upcoming = @upcoming_source.call.dup.freeze
        @total_duration = total_duration
        @selection.replace(@upcoming)
        @previous = @history_source.call.first(HISTORY_LIMIT).dup.freeze
        rebuild_rows
        nil
      end

      def display_rows(height)
        return [] unless height.positive?

        previous_block = previous_rows_for(height - UPCOMING_MIN_ROWS)
        upcoming_rows_for(height - previous_block.size) + previous_block
      end

      def render(screen, x:, y:, w:, h:, theme:, active: false) # rubocop:disable Naming/MethodParameterName
        range = @selection.selected_range
        display_rows(h).each_with_index do |row, index|
          case row[:type]
          when :header
            screen.put(y + index, x, ListRowRenderer.header_line(row[:text], w),
                       fg: theme[:info], bold: true)
          when :empty
            screen.put(y + index, x, row[:text][0, w], fg: theme[:text_muted])
          else
            # Upcoming rows carry their queue position; history rows don't.
            position = row[:queue_index]
            selected = active && position && position == @selection.selection
            # Rows of a Shift+arrow range are shaded behind the cursor.
            bg = theme[:surface_alt] if !selected && position && range&.cover?(position)
            screen.put(y + index, x, ' ' * w, bg: bg) if bg
            ListRowRenderer.render_track(
              screen, row, x: x, y: y + index, w: w,
                           selected:, bg: bg, theme: theme
            )
          end
        end
        nil
      end

      private

      def rebuild_rows
        @upcoming_rows = build_rows(@upcoming, formatter: @formatter, star_glyph: @star_glyph, indexed: true)
        @previous_rows = build_rows(@previous, formatter: @formatter, star_glyph: @star_glyph)
      end

      # `indexed` rows record their queue position for selection drawing.
      def build_rows(tracks, formatter:, star_glyph:, indexed: false)
        tracks.each_with_index.map do |track, index|
          row = ListRowRenderer.track(track, formatter: formatter, star_glyph: star_glyph)
          indexed ? row.merge(queue_index: index) : row
        end
      end

      def previous_rows_for(height)
        return [] unless height.positive?

        body = if @previous_rows.empty?
                 [{ type: :empty, text: 'No playback history yet' }]
               else
                 @previous_rows
               end
        body_capacity = [height - 1, 0].max
        [{ type: :header, text: 'Previously' }] + body.first(body_capacity)
      end

      def upcoming_rows_for(height)
        return [] unless height.positive?

        header = { type: :header, text: "Upcoming (#{@upcoming.size}/#{@total_duration})" }
        body_capacity = height - 1
        return [header] unless body_capacity.positive?
        return [header, { type: :empty, text: 'Queue empty' }] if @upcoming_rows.empty?

        # The "+ N more" note never takes the selected track's only row.
        note = @upcoming_rows.size > body_capacity && body_capacity > 1
        visible, hidden_count = @selection.visible_items(note ? body_capacity - 1 : body_capacity)
        rows = [header] + @upcoming_rows[@selection.scroll, visible.size].to_a
        return rows unless note && hidden_count.positive?

        rows + [{ type: :empty, text: "+ #{hidden_count} more" }]
      end

      def total_duration
        known_ms = @upcoming.filter_map(&:display_duration_ms).sum
        text = DurationFormatter.format(known_ms)
        text = "~#{text}" if @upcoming.any?(&:planned_duration?)
        @upcoming.any? { |track| track.display_duration_ms.nil? } ? "#{text} + ??" : text
      end
    end
  end
end
