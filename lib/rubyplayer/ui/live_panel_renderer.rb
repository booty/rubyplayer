# frozen_string_literal: true

module RubyPlayer
  module UI
    # Drawing shared by the full-screen live pages (SpcLiveView,
    # VgmLiveView): equal-width columns of panels, each a list of lines
    # clipped to the page's rectangle, and a one-entry cache per panel.
    # Each page keeps its own layout (which panels fit where).
    #
    # Expects @screen, @theme, @left, @top, @width, @height, and @caches.
    module LivePanelRenderer
      COLUMN_GAP = 2

      private

      def render_columns(top, rows, panels)
        width = column_width(panels.size)
        panels.each_with_index do |panel, index|
          render_block(top, index * (width + COLUMN_GAP), width, rows, panel)
        end
      end

      def column_width(count) = (@width - (COLUMN_GAP * (count - 1))) / count

      # Lines are { text:, color:, bold: } or { segments: [[text, color, bold], ...] }.
      def render_block(top, column, width, rows, lines)
        lines.first([rows, 0].max).each_with_index do |item, index|
          if item[:segments]
            put_segments(top + index, column, width, item[:segments])
          else
            put(top + index, item[:text][0, width], column: column, fg: @theme[item[:color] || :text],
                                                    bold: item[:bold] || false)
          end
        end
      end

      def put_segments(row, column, width, segments)
        offset = 0
        segments.each do |text, color, bold|
          break if offset >= width

          put(row, text[0, width - offset], column: column + offset, fg: @theme[color || :text], bold: bold || false)
          offset += text.length
        end
      end

      # One entry per panel: a result is reused only while that panel's own
      # inputs are unchanged, so memory stays bounded and unrelated changes
      # (an instrument switch) don't discard it. Building graph lines every
      # frame dominated render time (~3 ms at 158 columns).
      def cached(panel_name, inputs)
        stored_inputs, value = @caches[panel_name]
        return value if @caches.key?(panel_name) && stored_inputs == inputs

        value = yield
        @caches[panel_name] = [inputs, value]
        value
      end

      # Track titles and chip warnings come from the file; the rest is ours.
      def sanitize(text) = text.to_s.gsub(/[[:cntrl:]]/, ' ')

      # Clips to the page's rectangle so nothing paints outside it.
      def put(row, text, column: 0, **style)
        available = @width - column
        return unless available.positive? && row.between?(0, @height - 1)

        @screen.put(@top + row, @left + column, text[0, available], **style)
      end
    end
  end
end
