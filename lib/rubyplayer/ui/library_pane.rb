module RubyPlayer
  module UI
    # Flattens fixed source/smart rows plus the
    # folder tree into a single visible-row list. Focus belongs here because it
    # is an app-level audio source, not a folder or database query, while shared
    # nav/selection logic still benefits from one row model.
    class LibraryPane
      include ScrollableList

      Row = Struct.new(:kind, :folder, :playlist, :depth, keyword_init: true)

      attr_reader :selection

      def initialize(library:, glyphs:)
        @library = library
        @glyphs = glyphs
        @expanded = { all: true, playlists: true }
        @selection = 0
        @scroll = 0
        @rows = []
        @page_size = ScrollableList::PAGE_SIZE_FALLBACK
      end

      def rebuild!
        @breadcrumbs = {}
        @rows = []
        # Views::ALL's insertion order is the sidebar order; :all is last so
        # the folder tree (its expanded children) renders directly beneath it.
        # Playlist children hang off :playlists the same way.
        Views::ALL.keys.each do |kind|
          @rows << Row.new(kind: kind, depth: 0)
          next unless kind == :playlists && @expanded[:playlists]

          @library.playlists.each do |playlist|
            @rows << Row.new(kind: :playlist, playlist: playlist, depth: 1)
          end
        end
        @library.roots.each { |f| append_folder(f, 1, []) } if @expanded[:all]
        @selection = @selection.clamp(0, [@rows.size - 1, 0].max)
      end

      def rows = @rows
      def selected = @rows[@selection]

      def breadcrumb_for(row)
        return "" unless row
        return "Playlists / #{row.playlist['name']}" if row.kind == :playlist
        return Views.label(row.kind) unless row.kind == :folder

        @breadcrumbs.fetch(row.folder["id"], row.folder["name"].to_s)
      end

      def select_playlist(id)
        @expanded[:playlists] = true
        rebuild!
        index = @rows.index { |r| r.kind == :playlist && r.playlist["id"] == id }
        @selection = index if index
        !!index
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
        follow_selection(h, @rows.size)
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

      def toggle_expand(open)
        row = selected
        case row&.kind
        when :all
          @expanded[:all] = open
        when :playlists
          @expanded[:playlists] = open
        when :folder
          @expanded[row.folder["id"]] = open
        else
          return
        end
        rebuild!
      end

      def label_for(row)
        if row.kind == :playlist
          ["#{@glyphs['playlist']} #{row.playlist['name']}", "(#{row.playlist['track_count']})"]
        elsif row.kind == :folder
          f = row.folder
          icon = @glyphs[f["kind"]] || @glyphs["dir"]
          ["#{icon} #{f['name']}", "(#{f['track_count']})"]
        else
          view = Views::ALL.fetch(row.kind)
          ["#{@glyphs[view.glyph]} #{view.label}", ""]
        end
      end
    end
  end
end
