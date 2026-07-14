module RubyPlayer
  module UI
    # Flattens fixed special rows (queue/history/favorites/focus) plus the
    # folder tree into a single visible-row list. Focus belongs here because it
    # is an app-level audio source, not a folder or database query, while shared
    # nav/selection logic still benefits from one row model.
    class LibraryPane
      Row = Struct.new(:kind, :folder, :depth, keyword_init: true)

      SPECIALS = [
        [:queue, "Playback Queue"],
        [:history, "History"],
        [:favorites, "Favorite Tracks"],
        [:focus, "Focus"],
      ].freeze

      attr_reader :selection

      def initialize(library:, glyphs:)
        @library = library
        @glyphs = glyphs
        @expanded = {}
        @selection = 0
        @scroll = 0
        @rows = []
        # Page-jump distance = the pane's height, captured at render time
        # (panes don't know their size otherwise; it changes on resize).
        # 10 is only the never-rendered fallback (tests, first keypress).
        @page_size = 10
      end

      def rebuild!
        @rows = SPECIALS.map { |kind, _| Row.new(kind: kind, depth: 0) }
        @library.roots.each { |f| append_folder(f, 0) }
        @selection = @selection.clamp(0, [@rows.size - 1, 0].max)
      end

      def rows = @rows
      def selected = @rows[@selection]

      def handle_action(action)
        case action
        when :nav_up then @selection = (@selection - 1).clamp(0, @rows.size - 1)
        when :nav_down then @selection = (@selection + 1).clamp(0, @rows.size - 1)
        when :nav_page_up then @selection = (@selection - @page_size).clamp(0, @rows.size - 1)
        when :nav_page_down then @selection = (@selection + @page_size).clamp(0, @rows.size - 1)
        when :expand then toggle_expand(true)
        when :collapse then toggle_expand(false)
        when :select_queue then @selection = 0
        else return false
        end
        true
      end

      def render(screen, x:, y:, w:, h:, active:, theme:)
        @page_size = h
        follow_selection(h)
        h.times do |i|
          row = @rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? theme[:selection_bg] : theme[:surface_alt]) : nil
          fg = selected ? theme[:selection_text] : theme[:text]
          screen.put(y + i, x, " " * w, bg: bg) if selected
          label, suffix = label_for(row)
          indent = "  " * row.depth
          screen.put(y + i, x, "#{indent}#{label}"[0, w], fg: fg, bg: bg, bold: selected)
          unless suffix.empty?
            col = x + indent.size + label.size + 1
            screen.put(y + i, col, suffix[0, [w - (col - x), 0].max],
                       fg: selected ? fg : theme[:text_muted], bg: bg)
          end
        end
      end

      private

      def append_folder(folder, depth)
        @rows << Row.new(kind: :folder, folder: folder, depth: depth)
        return unless @expanded[folder["id"]]
        @library.children_of(folder["id"]).each { |c| append_folder(c, depth + 1) }
      end

      def toggle_expand(open)
        row = selected
        return unless row&.kind == :folder
        @expanded[row.folder["id"]] = open
        rebuild!
      end

      def follow_selection(height)
        @scroll = @selection if @selection < @scroll
        @scroll = @selection - height + 1 if @selection >= @scroll + height
        @scroll = @scroll.clamp(0, [@rows.size - height, 0].max)
      end

      def label_for(row)
        case row.kind
        when :queue then ["#{@glyphs['play']} Playback Queue", ""]
        when :history then ["#{@glyphs['playlist']} History", ""]
        when :favorites then ["#{@glyphs['star']} Favorite Tracks", ""]
        when :focus then ["#{@glyphs['focus']} Focus", ""]
        when :folder
          f = row.folder
          icon = @glyphs[f["kind"]] || @glyphs["dir"]
          ["#{icon} #{f['name']}", "(#{f['track_count']})"]
        end
      end
    end
  end
end
