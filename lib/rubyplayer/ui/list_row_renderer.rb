# frozen_string_literal: true

module RubyPlayer
  module UI
    # Shared stateless construction and drawing for formatted list rows.
    module ListRowRenderer
      module_function

      def track(track, formatter:, star_glyph:, album_artist: nil)
        segments = TrackFormatter.render(
          formatter, track, album_artist: album_artist, star_glyph: star_glyph
        )
        { type: :track, text: segments.map { |segment| segment[:text] }.join,
          segments: segments, track: track }
      end

      def render_track(screen, row, x:, y:, w:, selected:, bg:, theme:) # rubocop:disable Naming/MethodParameterName
        col = x
        remaining = w
        row[:segments].each do |segment|
          break if remaining <= 0
          next if segment[:text].empty?

          chunk = segment[:text][0, remaining]
          fg = selected ? theme[:selection_text] : resolve_color(segment[:fg] || :text, theme)
          segment_bg = selected ? theme[:selection_bg] : resolve_color(segment[:bg], theme)
          screen.put(y, col, chunk, fg: fg, bg: segment_bg || bg,
                                    bold: selected || segment[:bold], italic: segment[:italic],
                                    underline: segment[:underline], dim: segment[:dim])
          col += chunk.size
          remaining -= chunk.size
        end
        nil
      end

      def header_line(label, width)
        prefix = "--- #{label} "
        return prefix[0, width] if prefix.size >= width

        "#{prefix}#{'-' * (width - prefix.size)}"
      end

      def resolve_color(color, theme)
        color.is_a?(Symbol) && theme.key?(color) ? theme[color] : color
      end
      private_class_method :resolve_color
    end
  end
end
