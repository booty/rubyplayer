module RubyPlayer
  module UI
    # Flattens fixed source/smart rows plus the
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
        [:recent, "Recently Added"],
        [:unrated, "Unrated"],
        [:missing, "Missing"],
        [:failed, "Failed to Scan"],
        [:most_played, "Most Played"],
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
        @breadcrumbs = {}
        @rows = SPECIALS.map { |kind, _| Row.new(kind: kind, depth: 0) }
        @library.roots.each { |f| append_folder(f, 0, []) }
        @selection = @selection.clamp(0, [@rows.size - 1, 0].max)
      end

      def rows = @rows
      def selected = @rows[@selection]

      def breadcrumb_for(row)
        return "" unless row
        return SPECIALS.to_h.fetch(row.kind) unless row.kind == :folder

        @breadcrumbs.fetch(row.folder["id"], row.folder["name"].to_s)
      end

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
        scrollbar = @rows.size > h
        content_w = scrollbar ? w - 1 : w
        h.times do |i|
          row = @rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? theme[:selection_bg] : theme[:surface_alt]) : nil
          fg = selected ? theme[:selection_text] : theme[:text]
          screen.put(y + i, x, " " * content_w, bg: bg) if selected
          label, suffix = label_for(row)
          indent = "  " * row.depth
          screen.put(y + i, x, "#{indent}#{label}"[0, content_w], fg: fg, bg: bg, bold: selected)
          unless suffix.empty?
            col = x + indent.size + label.size + 1
            screen.put(y + i, col, suffix[0, [content_w - (col - x), 0].max],
                       fg: selected ? fg : theme[:text_muted], bg: bg)
          end
        end
        draw_scrollbar(screen, x: x + w - 1, y: y, h: h, total: @rows.size,
                       theme: theme) if scrollbar
      end

      private

      def append_folder(folder, depth, ancestors)
        path = ancestors + [folder["name"]]
        @breadcrumbs[folder["id"]] = path.join(" / ")
        @rows << Row.new(kind: :folder, folder: folder, depth: depth)
        return unless @expanded[folder["id"]]
        @library.children_of(folder["id"]).each { |c| append_folder(c, depth + 1, path) }
      end

      def draw_scrollbar(screen, x:, y:, h:, total:, theme:)
        thumb_size = [h * h / total, 1].max
        thumb_start = @scroll * (h - thumb_size) / [total - h, 1].max
        h.times do |offset|
          glyph = offset.between?(thumb_start, thumb_start + thumb_size - 1) ? "█" : "│"
          screen.put(y + offset, x, glyph, fg: theme[:text_muted])
        end
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
        when :recent then ["#{@glyphs['playlist']} Recently Added", ""]
        when :unrated then ["#{@glyphs['playlist']} Unrated", ""]
        when :missing then ["#{@glyphs['missing']} Missing", ""]
        when :failed then ["#{@glyphs['errored']} Failed to Scan", ""]
        when :most_played then ["#{@glyphs['play']} Most Played", ""]
        when :folder
          f = row.folder
          icon = @glyphs[f["kind"]] || @glyphs["dir"]
          ["#{icon} #{f['name']}", "(#{f['track_count']})"]
        end
      end
    end
  end
end
