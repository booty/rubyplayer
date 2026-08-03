# frozen_string_literal: true

module RubyPlayer
  module UI
    # Read-only overview of upcoming playback and recent history.
    class QueuedPane
      HISTORY_LIMIT = 3
      PreparedConfig = Data.define(:formatter, :star_glyph, :upcoming_rows, :previous_rows)
      private_constant :PreparedConfig

      attr_reader :upcoming, :previous

      def initialize(config:, upcoming_source:, history_source:)
        @upcoming_source = upcoming_source
        @history_source = history_source
        @upcoming = @upcoming_source.call.dup.freeze
        @previous = @history_source.call.first(HISTORY_LIMIT).dup.freeze
        update_config(config)
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
          upcoming_rows: build_rows(@upcoming, formatter:, star_glyph:),
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
        @previous = @history_source.call.first(HISTORY_LIMIT).dup.freeze
        rebuild_rows
        nil
      end

      def display_rows(height)
        return [] unless height.positive?

        previous_block = previous_rows_for(height)
        remaining = height - previous_block.size
        return previous_block if remaining <= 0

        upcoming_rows_for(remaining) + previous_block
      end

      def render(screen, x:, y:, w:, h:, theme:) # rubocop:disable Naming/MethodParameterName
        display_rows(h).each_with_index do |row, index|
          case row[:type]
          when :header
            screen.put(y + index, x, ListRowRenderer.header_line(row[:text], w),
                       fg: theme[:info], bold: true)
          when :empty
            screen.put(y + index, x, row[:text][0, w], fg: theme[:text_muted])
          else
            ListRowRenderer.render_track(
              screen, row, x: x, y: y + index, w: w,
                           selected: false, bg: nil, theme: theme
            )
          end
        end
        nil
      end

      private

      def rebuild_rows
        @upcoming_rows = build_rows(@upcoming, formatter: @formatter, star_glyph: @star_glyph)
        @previous_rows = build_rows(@previous, formatter: @formatter, star_glyph: @star_glyph)
      end

      def build_rows(tracks, formatter:, star_glyph:)
        tracks.map do |track|
          ListRowRenderer.track(track, formatter: formatter, star_glyph: star_glyph)
        end
      end

      def previous_rows_for(height)
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

        header = { type: :header, text: "Upcoming (#{@upcoming.size}/#{total_duration})" }
        body_capacity = height - 1
        return [header] unless body_capacity.positive?
        return [header, { type: :empty, text: 'Queue empty' }] if @upcoming_rows.empty?
        return [header] + @upcoming_rows if @upcoming_rows.size <= body_capacity

        visible_count = [body_capacity - 1, 0].max
        hidden_count = @upcoming_rows.size - visible_count
        [header] + @upcoming_rows.first(visible_count) +
          [{ type: :empty, text: "+ #{hidden_count} more" }]
      end

      def total_duration
        known_ms = @upcoming.filter_map(&:duration_ms).sum
        text = DurationFormatter.format(known_ms)
        @upcoming.any? { |track| track.duration_ms.nil? } ? "#{text} + ??" : text
      end
    end
  end
end
