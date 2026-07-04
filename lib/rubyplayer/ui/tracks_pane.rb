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
        return flat_rows unless @group_by_album
        grouped_rows
      end

      def selected_track
        row = display_rows[@selection]
        row && row[:type] == :track ? row[:track] : nil
      end

      def render(screen, x:, y:, w:, h:, active:)
        rows = display_rows
        follow_selection(h, rows.size)
        h.times do |i|
          row = rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? :blue : :bright_black) : nil
          screen.put(y + i, x, " " * w, bg: bg) if selected
          if row[:type] == :header
            screen.put(y + i, x, row[:text][0, w], fg: :cyan, bg: bg, bold: true)
          else
            screen.put(y + i, x, row[:text][0, w],
                       fg: selected ? :bright_white : nil, bg: bg, bold: selected)
          end
        end
      end

      private

      def flat_rows
        @tracks.map { |t| { type: :track, text: @flat_template.render(t), track: t } }
      end

      def grouped_rows
        groups = @tracks.group_by { |t| t.album.to_s }.sort_by { |album, _| album }
        groups.flat_map do |album, tracks|
          album_artist = tracks.map(&:artist).tally.max_by { |_, n| n }&.first
          [{ type: :header, text: album }] + tracks.map do |t|
            { type: :track, text: @grouped_template.render(t, album_artist: album_artist),
              track: t }
          end
        end
      end

      def apply_sort
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
