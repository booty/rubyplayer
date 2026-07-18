module RubyPlayer
  module UI
    # Scroll/selection mechanics shared by the list panes. LibraryPane and
    # TracksPane carried byte-identical copies of these; the scrollbar math
    # in particular is easy to drift apart silently since a subtly-wrong
    # thumb still "looks scrollbar-ish" in a TTY.
    #
    # Includers own @selection, @scroll, and @page_size. Page-jump distance
    # equals the pane's height, captured at render time (panes don't know
    # their size otherwise; it changes on resize) — PAGE_SIZE_FALLBACK only
    # covers the never-rendered case (tests, first keypress).
    module ScrollableList
      PAGE_SIZE_FALLBACK = 10

      private

      def follow_selection(height, total)
        @scroll = @selection if @selection < @scroll
        @scroll = @selection - height + 1 if @selection >= @scroll + height
        @scroll = @scroll.clamp(0, [total - height, 0].max)
      end

      def draw_scrollbar(screen, x:, y:, h:, total:, theme:)
        # Thumb area is viewport/total; travel maps current scroll across
        # remaining track so first and last pages reach opposite pane edges.
        thumb_size = [h * h / total, 1].max
        thumb_start = @scroll * (h - thumb_size) / [total - h, 1].max
        h.times do |offset|
          glyph = offset.between?(thumb_start, thumb_start + thumb_size - 1) ? "█" : "│"
          screen.put(y + offset, x, glyph, fg: theme[:text_muted])
        end
      end
    end
  end
end
