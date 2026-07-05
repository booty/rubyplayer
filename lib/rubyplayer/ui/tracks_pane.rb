module RubyPlayer
  module UI
    class TracksPane
      attr_reader :selection

      def initialize(library:, config:, queue_source:)
        @library = library
        @queue_source = queue_source
        @mode = nil
        @tracks = []
        @selection = 0
        @scroll = 0
        @group_by_album = false
        @sort = nil
        update_config(config)
      end

      def update_config(config)
        star = config["glyphs", "star"]
        @grouped_template = Template.new(config["ui", "format_string_grouped"], star_glyph: star)
        @flat_template = Template.new(config["ui", "format_string_ungrouped"], star_glyph: star)
        @history_limit = config["library", "history_limit"]
      end

      def show(library_row)
        @mode = library_row.kind == :folder ? [:folder, library_row.folder["id"]] : library_row.kind
        # @group_by_album/@sort are the user's preference and are shared across
        # views (folder/history/favorites/queue) -- they are NOT reset here.
        # Resetting them on entering :queue used to destroy a folder's sort as
        # a side effect of merely peeking the queue. Instead, apply_sort and
        # display_rows force the queue to render flat/unsorted regardless of
        # these flags (see below), so the stored preference survives the trip.
        @selection = 0
        @scroll = 0
        reload!
      end

      def reload!
        @tracks =
          case @mode
          when :queue then @queue_source.call
          when :history then @library.history(limit: @history_limit).map { |h| h[:track] }
          when :favorites then @library.favorites
          when Array then @library.tracks_under(@mode[1])
          else []
          end
        apply_sort
        clamp_selection
      end

      def handle_action(action)
        # Sort/group keys are no-ops while viewing the queue: apply_sort and
        # display_rows already force flat/unsorted rendering in :queue mode
        # (see below), so honoring these here would just flip flags with no
        # visible effect -- swallow them instead of confusing the user.
        return true if @mode == :queue && %i[toggle_group sort_title sort_number sort_artist].include?(action)
        case action
        when :nav_up then move_selection(-1)
        when :nav_down then move_selection(1)
        when :toggle_group then @group_by_album = !@group_by_album
        when :sort_title then @sort = :title
        when :sort_number then @sort = :number
        when :sort_artist then @sort = :artist
        else return false
        end
        apply_sort if %i[sort_title sort_number sort_artist toggle_group].include?(action)
        clamp_selection
        true
      end

      def display_rows
        # The queue is an ordered play list (see #show); album headers would
        # break the row-index-to-queue-index mapping that selected_track_index
        # relies on, so ignore @group_by_album here regardless of its value
        # for other views.
        return flat_rows if @mode == :queue
        return flat_rows unless @group_by_album
        grouped_rows
      end

      def selected_track
        row = display_rows[@selection]
        row && row[:type] == :track ? row[:track] : nil
      end

      # Index of the selected row among :track rows only (headers don't
      # count). In the queue view there are no headers, so this equals the
      # queue position directly -- that's what callers removing from the
      # live queue (App#dispatch :remove_from_queue) need.
      def selected_track_index
        rows = display_rows
        row = rows[@selection]
        return nil unless row && row[:type] == :track

        rows[0..@selection].count { |r| r[:type] == :track } - 1
      end

      def render(screen, x:, y:, w:, h:, active:, theme:)
        rows = display_rows
        follow_selection(h, rows.size)
        h.times do |i|
          row = rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? theme[:selection_bg] : theme[:surface_alt]) : nil
          screen.put(y + i, x, " " * w, bg: bg) if selected
          if row[:type] == :header
            screen.put(y + i, x, header_line(row[:text], w), fg: theme[:info], bg: bg, bold: true)
          else
            render_track_row(screen, row, x, y + i, w, selected: selected, bg: bg, theme: theme)
          end
        end
      end

      private

      ITALIC_FIELDS = %w[artist artist?].freeze

      # Renders row[:segments] (see Template#render_segments) one field at a
      # time instead of one big string, so title/artist/duration can each
      # carry their own style -- title always bold, artist always italic,
      # duration muted when the row isn't the selected one (selection's own
      # fg takes over then, for readability against the highlight).
      def render_track_row(screen, row, x, y, w, selected:, bg:, theme:)
        col = x
        remaining = w
        row[:segments].each do |seg|
          break if remaining <= 0
          next if seg[:text].empty?

          chunk = seg[:text][0, remaining]
          fg = selected ? theme[:selection_text] : (seg[:field] == "duration" ? theme[:text_muted] : theme[:text])
          screen.put(y, col, chunk, fg: fg, bg: bg,
                     bold: selected || seg[:field] == "title",
                     italic: ITALIC_FIELDS.include?(seg[:field]))
          col += chunk.size
          remaining -= chunk.size
        end
      end

      # "--- Album Name ------..." with the trailing run of dashes extending
      # to the pane's right edge. Built at render time (not baked into the
      # row in #grouped_rows) since it depends on the pane width, which can
      # change on terminal resize.
      def header_line(album, w)
        prefix = "--- #{album} "
        return prefix[0, w] if prefix.size >= w

        "#{prefix}#{'-' * (w - prefix.size)}"
      end

      def flat_rows
        @tracks.map do |t|
          { type: :track, text: @flat_template.render(t),
            segments: @flat_template.render_segments(t), track: t }
        end
      end

      def grouped_rows
        groups = @tracks.group_by { |t| t.album.to_s }.sort_by { |album, _| album }
        groups.flat_map do |album, tracks|
          album_artist = tracks.map(&:artist).tally.max_by { |_, n| n }&.first
          [{ type: :header, text: album }] + tracks.map do |t|
            { type: :track, text: @grouped_template.render(t, album_artist: album_artist),
              segments: @grouped_template.render_segments(t, album_artist: album_artist),
              track: t }
          end
        end
      end

      def apply_sort
        # The queue's displayed order must equal engine.queue_items (playback
        # order), since App#dispatch(:remove_from_queue) removes by displayed
        # index -- a lingering @sort from another view must not reorder it.
        return if @mode == :queue

        case @sort
        when :title then @tracks.sort_by! { |t| t.title.to_s.downcase }
        when :number then @tracks.sort_by! { |t| [t.album.to_s, t.track_number || 0] }
        when :artist then @tracks.sort_by! { |t| [t.artist.to_s.downcase, t.title.to_s.downcase] }
        end
      end

      def move_selection(delta)
        rows = display_rows
        i = @selection
        loop do
          i += delta
          return unless i.between?(0, rows.size - 1)
          break if rows[i][:type] == :track
        end
        @selection = i
      end

      def clamp_selection
        rows = display_rows
        @selection = @selection.clamp(0, [rows.size - 1, 0].max)
        # never rest on a header
        if rows[@selection] && rows[@selection][:type] == :header
          @selection += 1 if @selection + 1 < rows.size
        end
      end

      def follow_selection(height, total)
        @scroll = @selection if @selection < @scroll
        @scroll = @selection - height + 1 if @selection >= @scroll + height
        @scroll = @scroll.clamp(0, [total - height, 0].max)
      end
    end
  end
end
