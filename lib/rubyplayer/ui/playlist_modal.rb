# frozen_string_literal: true

module RubyPlayer
  module UI
    # Snapshot-backed picker. Returns user intents; App owns mutations and refresh.
    class PlaylistModal
      attr_reader :track, :filter, :selection, :confirm
      attr_accessor :error

      def initialize(library:, track:, recent_count:)
        @library = library
        @track = track
        @recent = library.playlists(sort: :recency).first(recent_count)
        @all = library.playlists(sort: :alpha)
        @filter = ''
        @selection = 0
        @confirm = nil
        @error = nil
      end

      def rows
        @rows ||= begin
          needle = @filter.strip.downcase
          filtered = @all.select { |playlist| playlist['name'].downcase.include?(needle) }
          result = @recent.map { |playlist| { kind: :playlist, playlist: playlist, recent: true } }
          result.concat(filtered.map { |playlist| { kind: :playlist, playlist: playlist } })
          result << { kind: :create } unless needle.empty?
          result
        end
      end

      def handle_key(key, edit_line:)
        return unless key.is_a?(String) # Pasted paths must stay inside the modal.
        return handle_confirm(key) if @confirm

        case key
        when 'escape' then [:cancel]
        when 'up' then move_selection(-1)
        when 'down' then move_selection(1)
        when 'enter' then choose_selected
        else
          edited = edit_line.call(@filter, key)
          return unless edited

          @filter = edited
          @rows = nil
          @row_labels = nil
          @error = nil
          move_selection(0)
        end
      end

      def render(screen, theme:, frame:)
        return render_confirmation(screen, theme: theme, frame: frame) if @confirm

        labels = row_labels.first([screen.rows - 9, 1].max)
        filter_line = "Filter/name: #{@filter}_"
        hint = '[enter] Add  [esc] Cancel'
        w = [(labels.map(&:size) + [filter_line.size, hint.size, (@error || '').size]).max + 6,
             screen.cols - 2].min
        h = labels.size + (@error ? 6 : 5)
        frame.call(title: 'Add to Playlist', w: w, h: h, hint: hint) do |x, y|
          screen.put(y + 1, x + 2, filter_line[0, w - 4], fg: theme[:accent])
          labels.each_with_index do |label, i|
            selected = !rows.empty? && i == @selection
            bg = selected ? theme[:selection_bg] : nil
            fg = selected ? theme[:selection_text] : theme[:text]
            screen.put(y + 2 + i, x + 1, ' ' * (w - 2), bg: bg) if selected
            screen.put(y + 2 + i, x + 2, label[0, w - 4], fg: fg, bg: bg, bold: selected)
          end
          screen.put(y + h - 3, x + 2, @error[0, w - 4], fg: theme[:error]) if @error
        end
      end

      private

      def row_labels
        @row_labels ||= begin
          labels = rows.map do |row|
            if row[:kind] == :create
              "+ New playlist: #{@filter.strip}"
            else
              "#{row[:recent] ? '* ' : '  '}#{row[:playlist]['name']} (#{row[:playlist]['track_count']})"
            end
          end
          labels.empty? ? ['(no playlists — type a name)'] : labels
        end
      end

      def move_selection(delta)
        @selection = (@selection + delta).clamp(0, [rows.size - 1, 0].max)
        nil
      end

      def choose_selected
        row = rows[@selection]
        return unless row
        return [:create, @filter.strip] if row[:kind] == :create

        playlist = row[:playlist]
        if @library.playlist_contains?(playlist['id'], @track.id)
          @confirm = playlist
          nil
        else
          [:add, playlist]
        end
      end

      def handle_confirm(key)
        case key
        when 'y', 'enter' then [:add, @confirm]
        when 'n', 'escape' then @confirm = nil
        end
      end

      def render_confirmation(screen, theme:, frame:)
        message = "Already in \"#{@confirm['name']}\". Add again?"
        prompt = '[y] Add duplicate    [n/esc] Back'
        w = [message.size, prompt.size].max + 4
        frame.call(title: 'Add to Playlist', w: w, h: 5) do |x, y|
          screen.put(y + 2, x + 2, message[0, w - 4], fg: theme[:accent], bold: true)
          screen.put(y + 3, x + 2, prompt[0, w - 4], fg: theme[:primary], bold: true)
        end
      end
    end
  end
end
