# frozen_string_literal: true

module RubyPlayer
  module UI
    # Block-character bars and graphs shared by the live chip pages.
    module LiveGlyphs
      LEVEL_GLYPHS = ' ▁▂▃▄▅▆▇█'
      BAR_PARTIALS = ['', '▏', '▎', '▍', '▌', '▋', '▊', '▉'].freeze

      module_function

      # Horizontal bar `width` cells wide, in eighth-cell steps.
      def level_bar(value, maximum, width)
        eighths = (value.clamp(0, maximum) * width * 8) / maximum
        bar = ('█' * (eighths / 8)) + BAR_PARTIALS[eighths % 8]
        bar.ljust(width)
      end

      def level_glyph(value, maximum)
        index = ((value.clamp(0, maximum) * (LEVEL_GLYPHS.length - 1)) / maximum.to_f).round
        LEVEL_GLYPHS[index]
      end

      # Vertical bar graph, `rows` tall, one column per value, in eighth
      # blocks. Returns line hashes for a panel ({ text:, color:, graph: }).
      def graph(values, maximum, rows, color: :primary)
        heights = values.map { |value| (value.clamp(0, maximum) * rows * 8 / maximum.to_f).round }
        Array.new(rows) do |row|
          floor = (rows - 1 - row) * 8
          text = heights.map do |height|
            filled = (height - floor).clamp(0, 8)
            filled.zero? ? ' ' : LEVEL_GLYPHS[filled]
          end.join
          { text: text, color: color, graph: true }
        end
      end
    end
  end
end
