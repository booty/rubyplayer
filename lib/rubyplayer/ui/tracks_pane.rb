# frozen_string_literal: true

require 'time'

module RubyPlayer
  module UI
    class TracksPane
      include ScrollableList

      SELECTABLE_ROW_TYPES = %i[track focus playlist].freeze
      EXTEND_ACTIONS = { extend_selection_up: :nav_up, extend_selection_down: :nav_down }.freeze
      private_constant :EXTEND_ACTIONS

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
        @filter = ''
        @view_states = {}
        @page_size = ScrollableList::PAGE_SIZE_FALLBACK
        @queue_selection = QueueSelection.new
        # Range selection: the row Shift+arrows started from, as a track
        # occurrence (see #track_occurrence); the range runs from it to the
        # cursor. Kept by occurrence so a reload (a rating) keeps it.
        @anchor_occurrence = nil
        update_config(config)
      end

      def update_config(config)
        @star_glyph = config['glyphs', 'star']
        @grouped_formatter = config['ui', 'format_track_grouped']
        @flat_formatter = config['ui', 'format_track_ungrouped']
        @history_limit = config['library', 'history_limit']
        invalidate_rows!
      end

      def show(library_row, breadcrumb: nil)
        save_view_state if @mode
        @anchor_occurrence = nil
        @mode =
          case library_row.kind
          when :folder then [:folder, library_row.folder['id']]
          when :playlist then [:playlist, library_row.playlist['id']]
          else library_row.kind
          end
        @breadcrumb = breadcrumb || library_row.folder&.fetch('name', nil)
        # @group_by_album/@sort are the user's preference and are shared across
        # views (folder/history/favorites/queue) -- they are NOT reset here.
        # Resetting them on entering :queue used to destroy a folder's sort as
        # a side effect of merely peeking the queue. Instead, apply_sort and
        # display_rows force the queue to render flat/unsorted regardless of
        # these flags (see below), so the stored preference survives the trip.
        state = @view_states.fetch(@mode, {})
        @filter = state.fetch(:filter, '')
        load_tracks
        restore_view_state(state)
      end

      def title(max_width: nil)
        label = if @mode.is_a?(Array)
                  ['Tracks', @breadcrumb].compact.join(' · ')
                else
                  Views.label(@mode) || 'Tracks'
                end
        count = filtered_tracks.size.to_s
        if !@filter.strip.empty? && !%i[focus playlists].include?(@mode)
          term = @filter.gsub("'") { "\\'" }
          count = "#{filtered_tracks.size} of #{@tracks.size} (Filter: '#{term}')"
        end
        text = "#{label} · #{count}"
        marked = range_track_count
        text += " · #{marked} selected" if marked && marked > 1
        return text unless max_width && text.size > max_width
        return text[-max_width, max_width] if max_width <= 1

        "…#{text[-(max_width - 1), max_width - 1]}"
      end

      def reload!
        identity = selected_identity
        previous_selection = @selection
        previous_scroll = @scroll
        load_tracks
        if @mode == :queue
          @queue_selection.restore(identity: identity&.at(1), fallback: previous_selection,
                                   scroll: previous_scroll)
          sync_queue_cursor
          return
        end
        restore_selection(identity, previous_selection)
        @scroll = previous_scroll
      end

      def filter=(value)
        identity = selected_identity
        @anchor_occurrence = nil
        @filter = value.to_s
        invalidate_rows!
        if @mode == :queue
          @queue_selection.replace(filtered_tracks)
          @queue_selection.restore(identity: identity&.at(1), fallback: 0,
                                   scroll: @scroll)
          sync_queue_cursor
          return
        end
        restore_selection(identity, 0)
      end

      def clear_filter = self.filter = ''

      # Ordered views keep the grouping preference but do not apply it.
      def grouped?
        @group_by_album && !%i[queue focus playlists].include?(@mode) && !playlist_tracks_view?
      end

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
        @queue_selection.replace(filtered_tracks) if @mode == :queue
      end

      def handle_action(action)
        # Sort/group keys are no-ops while viewing the queue: apply_sort and
        # display_rows already force flat/unsorted rendering in :queue mode
        # (see below), so honoring these here would just flip flags with no
        # visible effect -- swallow them instead of confusing the user.
        if %i[queue focus].include?(@mode) &&
           %i[toggle_group sort_title sort_number sort_artist sort_year].include?(action)
          noun = @mode == :queue ? 'Queue order' : 'Focus sounds'
          return [:disabled, "#{noun} cannot be sorted or grouped"]
        end
        if playlist_tracks_view? &&
           %i[toggle_group sort_title sort_number sort_artist sort_year].include?(action)
          return [:disabled, 'Playlist order is fixed — ctrl+arrows move tracks']
        end

        if @mode == :queue && (EXTEND_ACTIONS.key?(action) || action == :clear_selection)
          handled = @queue_selection.handle_action(action)
          sync_queue_cursor
          return handled
        end
        return extend_selection(EXTEND_ACTIONS[action]) if EXTEND_ACTIONS.key?(action)

        # Escape, and any other movement, sort, or grouping, ends a range.
        had_range = !@anchor_occurrence.nil?
        @anchor_occurrence = nil
        return had_range if action == :clear_selection

        if @mode == :queue && %i[nav_up nav_down nav_page_up nav_page_down].include?(action)
          handled = @queue_selection.handle_action(action)
          sync_queue_cursor
          return handled
        end

        if @mode == :playlists
          case action
          when :sort_title
            @playlist_sort = @playlist_sort == :alpha ? :recency : :alpha
            load_tracks
            clamp_selection
            return true
          when :toggle_group, :sort_number, :sort_artist, :sort_year
            return [:disabled, 'Playlists sort by name/recency — Y toggles']
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
        return @queue_selection.selected_track if @mode == :queue

        row = display_rows[@selection]
        row && row[:type] == :track ? row[:track] : nil
      end

      # The tracks an action applies to: the range's, in list order, or the
      # cursor's track alone.
      def selected_tracks
        return @queue_selection.selected_tracks if @mode == :queue

        range = selected_row_range
        return [selected_track].compact unless range

        display_rows[range].filter_map { |row| row[:track] if row[:type] == :track }
      end

      def range_selected? = !selected_row_range.nil?

      # Display-row indexes from the anchor to the cursor, or nil without a
      # range (or once the anchor's occurrence has left the view). The anchor's
      # row is cached per row list, since render and title ask every frame.
      def selected_row_range
        # Queue rows are flat, so item indexes are row indexes.
        return @queue_selection.selected_range if @mode == :queue
        return unless @anchor_occurrence

        rows = display_rows
        cache = @anchor_cache
        unless cache && cache[0].equal?(rows) && cache[1] == @anchor_occurrence
          @anchor_cache = [rows, @anchor_occurrence, row_index_of(*@anchor_occurrence)]
        end
        anchor = @anchor_cache.last
        return @anchor_occurrence = nil unless anchor

        anchor < @selection ? (anchor..@selection) : (@selection..anchor)
      end

      # Track positions (headers skipped) of selected_tracks: the range's,
      # or the cursor's alone.
      def selected_track_indexes
        return @queue_selection.selected_indexes if @mode == :queue

        range = selected_row_range
        return [selected_track_index].compact unless range

        rows = display_rows
        position = rows[0...range.min].count { |row| row[:type] == :track }
        Array.new(range_track_count) { |offset| position + offset }
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
        return @queue_selection.selected_index if @mode == :queue

        rows = display_rows
        row = rows[@selection]
        return nil unless row && row[:type] == :track

        rows[0..@selection].count { |r| r[:type] == :track } - 1
      end

      def render(screen, x:, y:, w:, h:, active:, theme:)
        rows = display_rows
        range = selected_row_range
        if @mode == :queue
          @queue_selection.set_page_size(h)
          @queue_selection.follow_selection(h)
          sync_queue_cursor
        else
          @page_size = h
          follow_selection(h, rows.size)
        end
        scrollbar = rows.size > h
        content_w = scrollbar ? w - 1 : w
        h.times do |i|
          row = rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = if selected
                 active ? theme[:selection_bg] : theme[:surface_alt]
               elsif range&.cover?(@scroll + i)
                 theme[:surface_alt]
               end
          screen.put(y + i, x, ' ' * content_w, bg: bg) if bg
          if row[:type] == :header
            screen.put(y + i, x, ListRowRenderer.header_line(row[:text], content_w),
                       fg: theme[:info], bg: bg, bold: true)
          elsif row[:type] == :empty
            screen.put(y + i, x, row[:text][0, content_w], fg: theme[:text_muted])
          else
            ListRowRenderer.render_track(
              screen, row, x: x, y: y + i, w: content_w,
                           selected: selected, bg: bg, theme: theme
            )
          end
        end
        return unless scrollbar

        draw_scrollbar(screen, x: x + w - 1, y: y, h: h, total: rows.size,
                               theme: theme)
      end

      private

      # Focus and Playlists rows are not tracks, so they take no ranges (the
      # queue view's live in its QueueSelection).
      def extend_selection(nav_action)
        return handle_action(nav_action) if %i[focus playlists].include?(@mode) || !selected_track

        anchor = @anchor_occurrence || track_occurrence(@selection)
        move_selection(nav_action == :nav_up ? -1 : 1)
        @anchor_occurrence = anchor
        true
      end

      # Track rows in the range: grouped views put album headers inside it.
      # Cached per row list and range, since the title asks every frame.
      def range_track_count
        range = selected_row_range
        return unless range
        return range.size unless grouped?

        rows = display_rows
        cache = @range_count_cache
        unless cache && cache[0].equal?(rows) && cache[1] == range
          @range_count_cache = [rows, range, rows[range].count { |row| row[:type] == :track }]
        end
        @range_count_cache.last
      end

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
        return 'No matches — press / to edit filter' unless @filter.empty? || @tracks.empty?

        case @mode
        when :queue then 'Queue empty — press N to add selected tracks'
        when :playlists then 'No playlists yet — press L on a track to create one'
        when :history then 'No playback history yet'
        when :favorites then 'No favorites yet — press 1–6 while a track plays'
        else 'No tracks in this view'
        end
      end

      def flat_rows
        filtered_tracks.map do |track|
          ListRowRenderer.track(track, formatter: @flat_formatter, star_glyph: @star_glyph)
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
            segments: [{ text: p['name'], bold: true },
                       { text: count, fg: :text_muted },
                       { text: used, fg: :text_muted }],
            playlist: p }
        end
      end

      def relative_time(iso)
        seconds = Time.now.utc - Time.parse(iso)
        return 'just now' if seconds < 60
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
          [{ type: :header, text: album }] + tracks.map do |track|
            ListRowRenderer.track(
              track, formatter: @grouped_formatter, star_glyph: @star_glyph,
                     album_artist: album_artist
            )
          end
        end
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
                     [item['name']]
                   else
                     [item.title, item.artist, item.album, item.composer,
                      item.physical_path, item.archive_entry]
                   end
          values.compact.any? { |value| value.to_s.downcase.include?(query) }
        end
      end

      def selected_identity
        return [:track, @queue_selection.selected_track.id] if @mode == :queue && @queue_selection.selected_track

        row = display_rows[@selection]
        case row&.dig(:type)
        when :track then [:track, *track_occurrence(@selection)]
        when :focus then [:focus, row[:focus_sound].id]
        when :playlist then [:playlist, row[:playlist]['id']]
        end
      end

      def save_view_state
        @view_states[@mode] = {
          filter: @filter, selection_identity: selected_identity,
          selection: @selection, scroll: @scroll
        }
      end

      def restore_view_state(state)
        if @mode == :queue
          @queue_selection.restore(identity: state[:selection_identity]&.at(1),
                                   fallback: state.fetch(:selection, 0),
                                   scroll: state.fetch(:scroll, 0))
          sync_queue_cursor
          return
        end
        restore_selection(state[:selection_identity], state.fetch(:selection, 0))
        @scroll = state.fetch(:scroll, 0)
      end

      def restore_selection(identity, fallback)
        if @mode == :queue
          @queue_selection.restore(identity: identity&.at(1), fallback: fallback, scroll: @scroll)
          sync_queue_cursor
          return
        end

        rows = display_rows
        match = if identity&.first == :track
                  row_index_of(identity[1], identity[2] || 0)
                else
                  rows.index do |row|
                    case identity&.first
                    when :focus then row[:type] == :focus && row[:focus_sound].id == identity[1]
                    when :playlist then row[:type] == :playlist && row[:playlist]['id'] == identity[1]
                    end
                  end
                end
        @selection = match || fallback
        clamp_selection
      end

      # A track row's identity: its id and which copy of that track it is,
      # since a playlist (or History) can list one track several times and
      # an id alone would always find the first copy.
      def track_occurrence(row_index)
        rows = display_rows
        id = rows[row_index][:track].id
        [id, rows[0...row_index].count { |row| row[:type] == :track && row[:track].id == id }]
      end

      # The display-row index of the `copy`th row of track `id`, or nil.
      def row_index_of(id, copy)
        seen = -1
        display_rows.index { |row| row[:type] == :track && row[:track].id == id && (seen += 1) == copy }
      end

      def move_selection(delta)
        rows = display_rows
        i = @selection
        loop do
          i += delta
          return unless i.between?(0, rows.size - 1)
          break if SELECTABLE_ROW_TYPES.include?(rows[i][:type])
        end
        @selection = i
      end

      def clamp_selection
        rows = display_rows
        @selection = @selection.clamp(0, [rows.size - 1, 0].max)
        # never rest on a header
        return unless rows[@selection] && rows[@selection][:type] == :header

        @selection += 1 if @selection + 1 < rows.size
      end

      def sync_queue_cursor
        @selection = @queue_selection.selection
        @scroll = @queue_selection.scroll
      end
    end
  end
end
