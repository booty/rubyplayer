require "time"

module RubyPlayer
  module UI
    class TracksPane
      include ScrollableList

      attr_reader :selection, :filter

      def initialize(library:, config:, queue_source:, focus_source: -> { FocusSounds::ALL })
        @library = library
        @queue_source = queue_source
        @focus_source = focus_source
        @mode = nil
        @tracks = []
        @selection = 0
        @scroll = 0
        @group_by_album = false
        @sort = nil
        @playlist_sort = :recency
        @filter = ""
        @view_states = {}
        @page_size = ScrollableList::PAGE_SIZE_FALLBACK
        update_config(config)
      end

      def update_config(config)
        @star_glyph = config["glyphs", "star"]
        @grouped_formatter = config["ui", "format_track_grouped"]
        @flat_formatter = config["ui", "format_track_ungrouped"]
        @history_limit = config["library", "history_limit"]
        invalidate_rows!
      end

      def show(library_row, breadcrumb: nil)
        save_view_state if @mode
        @mode =
          case library_row.kind
          when :folder then [:folder, library_row.folder["id"]]
          when :playlist then [:playlist, library_row.playlist["id"]]
          else library_row.kind
          end
        @breadcrumb = breadcrumb || library_row.folder&.fetch("name", nil)
        # @group_by_album/@sort are the user's preference and are shared across
        # views (folder/history/favorites/queue) -- they are NOT reset here.
        # Resetting them on entering :queue used to destroy a folder's sort as
        # a side effect of merely peeking the queue. Instead, apply_sort and
        # display_rows force the queue to render flat/unsorted regardless of
        # these flags (see below), so the stored preference survives the trip.
        state = @view_states.fetch(@mode, {})
        @filter = state.fetch(:filter, "")
        load_tracks
        restore_view_state(state)
      end

      def title(max_width: nil)
        label = if @mode.is_a?(Array)
                  ["Tracks", @breadcrumb].compact.join(" · ")
                else
                  Views.label(@mode) || "Tracks"
                end
        text = "#{label} · #{filtered_tracks.size}"
        return text unless max_width && text.size > max_width
        return text[-max_width, max_width] if max_width <= 1

        "…#{text[-(max_width - 1), max_width - 1]}"
      end

      def reload!
        identity = selected_identity
        previous_selection = @selection
        previous_scroll = @scroll
        load_tracks
        restore_selection(identity, previous_selection)
        @scroll = previous_scroll
      end

      def filter=(value)
        identity = selected_identity
        @filter = value.to_s
        invalidate_rows!
        restore_selection(identity, 0)
      end

      def clear_filter = self.filter = ""

      def load_tracks
        # Focus reuses this pane's navigation and rendering shell, but its rows
        # carry FocusSound values rather than Track records. Keeping a distinct
        # row type prevents queue/rating/info actions from treating recipes as
        # database-backed tracks.
        @tracks =
          case @mode
          when :queue then @queue_source.call
          when :focus then @focus_source.call
          # History can't live in the Views query table: it takes a
          # config-driven limit and returns {track:, started_at:} rows that
          # need unwrapping, unlike the plain track-list queries.
          when :history then @library.history(limit: @history_limit).map { |h| h[:track] }
          when :playlists then @library.playlists(sort: @playlist_sort)
          when Array
            @mode[0] == :playlist ? @library.playlist_tracks(@mode[1]) : @library.tracks_under(@mode[1])
          else Views.query(@mode, @library)
          end
        apply_sort
      end

      def handle_action(action)
        # Sort/group keys are no-ops while viewing the queue: apply_sort and
        # display_rows already force flat/unsorted rendering in :queue mode
        # (see below), so honoring these here would just flip flags with no
        # visible effect -- swallow them instead of confusing the user.
        if %i[queue focus].include?(@mode) &&
           %i[toggle_group sort_title sort_number sort_artist sort_year].include?(action)
          noun = @mode == :queue ? "Queue order" : "Focus sounds"
          return [:disabled, "#{noun} cannot be sorted or grouped"]
        end
        if playlist_tracks_view? &&
           %i[toggle_group sort_title sort_number sort_artist sort_year].include?(action)
          return [:disabled, "Playlist order is fixed — ctrl+arrows move tracks"]
        end
        if @mode == :playlists
          case action
          when :sort_title
            @playlist_sort = @playlist_sort == :alpha ? :recency : :alpha
            load_tracks
            clamp_selection
            return true
          when :toggle_group, :sort_number, :sort_artist, :sort_year
            return [:disabled, "Playlists sort by name/recency — Y toggles"]
          end
        end
        case action
        when :nav_up then move_selection(-1)
        when :nav_down then move_selection(1)
        # Page jumps land by index (headers included), then the shared
        # clamp_selection below nudges off a header if one was hit.
        when :nav_page_up then @selection = (@selection - @page_size).clamp(0, [display_rows.size - 1, 0].max)
        when :nav_page_down then @selection = (@selection + @page_size).clamp(0, [display_rows.size - 1, 0].max)
        when :toggle_group then @group_by_album = !@group_by_album
        when :sort_title then @sort = :title
        when :sort_number then @sort = :number
        when :sort_artist then @sort = :artist
        when :sort_year then @sort = :year
        else return false
        end
        apply_sort if %i[sort_title sort_number sort_artist sort_year toggle_group].include?(action)
        clamp_selection
        true
      end

      # Memoized: this is called several times per keypress and once per
      # 30fps frame (render, selected_track, clamp_selection, ...), and
      # rebuilding runs TrackFormatter over every filtered track — on a
      # 10k-track All Songs view that's hundreds of thousands of formatter
      # calls per second for rows that haven't changed. Every mutation path
      # (load_tracks/apply_sort, filter=, update_config) must call
      # invalidate_rows! or the pane renders stale rows.
      def display_rows
        @rows_cache ||= build_rows
      end

      def selected_track
        row = display_rows[@selection]
        row && row[:type] == :track ? row[:track] : nil
      end

      def selected_focus_sound
        # Callers must opt into the Focus type explicitly; selected_track stays
        # nil in this mode so generic enqueue paths cannot accept these rows.
        row = display_rows[@selection]
        row && row[:type] == :focus ? row[:focus_sound] : nil
      end

      def selected_queue_track
        @mode == :queue ? selected_track : nil
      end

      def selected_playlist
        row = display_rows[@selection]
        row && row[:type] == :playlist ? row[:playlist] : nil
      end

      # Non-nil only while showing a playlist's tracks — App's move/remove
      # entry actions gate on it.
      def playlist_id
        @mode.is_a?(Array) && @mode[0] == :playlist ? @mode[1] : nil
      end

      def visible_tracks
        # Return fresh array so App can capture confirmation target without a
        # later filter/reload mutating meaning of pending destructive action.
        filtered_tracks.select { |item| item.is_a?(Track) }.dup
      end

      # Resolve queue position from selected Track identity. Display indexes
      # become unsafe once filtering can hide rows before selected item.
      def selected_track_index
        return @tracks.index { |track| track.equal?(selected_track) } if @mode == :queue

        rows = display_rows
        row = rows[@selection]
        return nil unless row && row[:type] == :track

        rows[0..@selection].count { |r| r[:type] == :track } - 1
      end

      def render(screen, x:, y:, w:, h:, active:, theme:)
        @page_size = h
        rows = display_rows
        follow_selection(h, rows.size)
        scrollbar = rows.size > h
        content_w = scrollbar ? w - 1 : w
        h.times do |i|
          row = rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? theme[:selection_bg] : theme[:surface_alt]) : nil
          screen.put(y + i, x, " " * content_w, bg: bg) if selected
          if row[:type] == :header
            screen.put(y + i, x, header_line(row[:text], content_w), fg: theme[:info], bg: bg, bold: true)
          elsif row[:type] == :empty
            screen.put(y + i, x, row[:text][0, content_w], fg: theme[:text_muted])
          else
            render_track_row(screen, row, x, y + i, content_w, selected: selected, bg: bg, theme: theme)
          end
        end
        draw_scrollbar(screen, x: x + w - 1, y: y, h: h, total: rows.size,
                       theme: theme) if scrollbar
      end

      private

      def invalidate_rows!
        @rows_cache = nil
        @filtered_cache = nil
      end

      def build_rows
        return [{ type: :empty, text: empty_message }] if filtered_tracks.empty?

        # The queue is an ordered play list (see #show); album headers would
        # break the row-index-to-queue-index mapping that selected_track_index
        # relies on, so ignore @group_by_album here regardless of its value
        # for other views.
        return flat_rows if @mode == :queue
        return focus_rows if @mode == :focus
        return playlist_rows if @mode == :playlists
        # Playlist tracks are position-ordered like the queue: headers would
        # break row-index == playlist-position, which move/remove rely on.
        return flat_rows if playlist_tracks_view?
        return flat_rows unless @group_by_album
        grouped_rows
      end

      def empty_message
        return "No matches — press / to edit filter" unless @filter.empty? || @tracks.empty?

        case @mode
        when :queue then "Queue empty — press N to add selected tracks"
        when :playlists then "No playlists yet — press L on a track to create one"
        when :history then "No playback history yet"
        when :favorites then "No favorites yet — press 1–6 while a track plays"
        else "No tracks in this view"
        end
      end

      # Selection owns foreground/background so every highlighted row remains
      # readable. Formatter text attributes survive selection.
      def render_track_row(screen, row, x, y, w, selected:, bg:, theme:)
        col = x
        remaining = w
        row[:segments].each do |seg|
          break if remaining <= 0
          next if seg[:text].empty?

          chunk = seg[:text][0, remaining]
          fg = selected ? theme[:selection_text] : resolve_color(seg[:fg] || :text, theme)
          segment_bg = selected ? theme[:selection_bg] : resolve_color(seg[:bg], theme)
          screen.put(y, col, chunk, fg: fg, bg: segment_bg || bg,
                     bold: selected || seg[:bold], italic: seg[:italic],
                     underline: seg[:underline], dim: seg[:dim])
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
        filtered_tracks.map do |t|
          segments = TrackFormatter.render(@flat_formatter, t, star_glyph: @star_glyph)
          { type: :track, text: segments.map { |segment| segment[:text] }.join,
            segments: segments, track: t }
        end
      end

      def playlist_tracks_view?
        @mode.is_a?(Array) && @mode[0] == :playlist
      end

      def playlist_rows
        filtered_tracks.map do |p|
          count = "  (#{p['track_count']})"
          used = "  #{relative_time(p['updated_at'])}"
          { type: :playlist, text: "#{p['name']}#{count}#{used}",
            segments: [{ text: p["name"], bold: true },
                       { text: count, fg: :text_muted },
                       { text: used, fg: :text_muted }],
            playlist: p }
        end
      end

      def relative_time(iso)
        seconds = Time.now.utc - Time.parse(iso)
        return "just now" if seconds < 60
        return "#{(seconds / 60).to_i}m ago" if seconds < 3600
        return "#{(seconds / 3600).to_i}h ago" if seconds < 86_400

        "#{(seconds / 86_400).to_i}d ago"
      end

      def focus_rows
        filtered_tracks.map do |sound|
          { type: :focus, text: sound.title,
            segments: [{ text: sound.title, bold: true }], focus_sound: sound }
        end
      end

      def grouped_rows
        groups = filtered_tracks.group_by { |t| [t.album_artist.to_s, t.album.to_s] }
                                .sort_by { |(album_artist, album), _| [album, album_artist] }
        groups.flat_map do |(_, album), tracks|
          # An explicit album_artist tag beats the majority-artist guess —
          # that guess is why compilations used to show every artist inline.
          album_artist = tracks.filter_map(&:album_artist).tally.max_by { |_, n| n }&.first ||
                         tracks.map(&:artist).tally.max_by { |_, n| n }&.first
          [{ type: :header, text: album }] + tracks.map do |t|
            segments = TrackFormatter.render(
              @grouped_formatter, t, album_artist: album_artist, star_glyph: @star_glyph
            )
            { type: :track, text: segments.map { |segment| segment[:text] }.join,
              segments: segments, track: t }
          end
        end
      end

      def resolve_color(color, theme)
        color.is_a?(Symbol) && theme.key?(color) ? theme[color] : color
      end

      def apply_sort
        # Every mutation route (show/reload!/load_tracks, sort and group keys)
        # funnels through here, so this is the one choke point that must drop
        # the row cache — including the queue/focus early return below, since
        # load_tracks just replaced @tracks for those modes too.
        invalidate_rows!
        # The queue's displayed order must equal engine.queue_items (playback
        # order), since App#dispatch(:remove_from_queue) removes by displayed
        # index -- a lingering @sort from another view must not reorder it.
        # Playlist tracks share that rule (position order), and the playlist
        # list orders itself via @playlist_sort in load_tracks.
        return if %i[queue focus playlists].include?(@mode) || playlist_tracks_view?

        case @sort
        when :title then @tracks.sort_by! { |t| t.title.to_s.downcase }
        when :number then @tracks.sort_by! { |t| [t.album.to_s, t.track_number || 0] }
        when :artist then @tracks.sort_by! { |t| [t.artist.to_s.downcase, t.title.to_s.downcase] }
        when :year then @tracks.sort_by! { |t| [t.year || 0, t.album.to_s, t.track_number || 0] }
        end
      end

      # Memoized alongside display_rows: #title re-counts matches every frame,
      # and the substring scan below is O(tracks × fields) — noticeable on
      # large views while a filter is active.
      def filtered_tracks
        @filtered_cache ||= compute_filtered_tracks
      end

      def compute_filtered_tracks
        query = @filter.strip.downcase
        return @tracks if query.empty?

        @tracks.select do |item|
          values = if @mode == :focus
                     [item.title]
                   elsif @mode == :playlists
                     [item["name"]]
                   else
                     [item.title, item.artist, item.album, item.composer,
                      item.physical_path, item.archive_entry]
                   end
          values.compact.any? { |value| value.to_s.downcase.include?(query) }
        end
      end

      def selected_identity
        row = display_rows[@selection]
        case row&.dig(:type)
        when :track then [:track, row[:track].id]
        when :focus then [:focus, row[:focus_sound].id]
        when :playlist then [:playlist, row[:playlist]["id"]]
        end
      end

      def save_view_state
        @view_states[@mode] = {
          filter: @filter, selection_identity: selected_identity,
          selection: @selection, scroll: @scroll
        }
      end

      def restore_view_state(state)
        restore_selection(state[:selection_identity], state.fetch(:selection, 0))
        @scroll = state.fetch(:scroll, 0)
      end

      def restore_selection(identity, fallback)
        rows = display_rows
        match = rows.index do |row|
          case identity&.first
          when :track then row[:type] == :track && row[:track].id == identity[1]
          when :focus then row[:type] == :focus && row[:focus_sound].id == identity[1]
          when :playlist then row[:type] == :playlist && row[:playlist]["id"] == identity[1]
          end
        end
        @selection = match || fallback
        clamp_selection
      end

      def move_selection(delta)
        rows = display_rows
        i = @selection
        loop do
          i += delta
          return unless i.between?(0, rows.size - 1)
          break if %i[track focus playlist].include?(rows[i][:type])
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

    end
  end
end
