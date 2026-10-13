# frozen_string_literal: true

module RubyPlayer
  module UI
    # The Now Playing bar under the panes: the playing track's title, rating,
    # and state; its credits and file facts; and a progress bar, beside a
    # spectrum as tall as the bar. App draws the border (the bar is a Tab
    # stop, so it uses the panes' focus style) and supplies the slower facts
    # as Details, read once per track. Short terminals get one line instead.
    class PlayerBar
      # credits: artist/album/year/composer text; file_facts: file type and
      # hardware or codec facts. Either may be nil. (Not `format`, which
      # would hide Kernel#format on every Details.)
      Details = Data.define(:rating, :credits, :file_facts) do
        # From a track and its stored metadata extras (Library#track_metadata_for).
        def self.for(track, extras:, rating:)
          new(rating: rating, credits: credits(track, extras), file_facts: file_facts(track, extras))
        end

        def self.credits(track, extras)
          album = [track.album, ("(#{track.year})" if track.year)].compact.join(' ') unless track.album.to_s.empty?
          total = " of #{extras['track_total']}" if extras['track_total']
          number = "track #{track.track_number}#{total}" if track.track_number
          composer = "composer #{track.composer}" unless [nil, '', track.artist].include?(track.composer)
          present([track.artist, album, number, composer])
        end

        # Chiptunes name their hardware and voices; decoded files their codec
        # and stream.
        def self.file_facts(track, extras)
          format = track.format.to_s.upcase
          codec = extras['codec'].to_s.upcase
          bit_rate = extras['bit_rate'].to_i
          sample_rate = extras['sample_rate'].to_i
          channels = { '1' => 'mono', '2' => 'stereo' }.fetch(extras['channels'].to_s) do
            "#{extras['channels']} channels" if extras['channels']
          end
          present([format, extras['sound_chips'], extras['voice_layout'], (codec unless [format, ''].include?(codec)),
                   ("#{bit_rate / 1000} kbps" if bit_rate.positive?),
                   (format('%g kHz', sample_rate / 1000.0) if sample_rate.positive?), channels])
        end

        def self.present(parts)
          parts = parts.reject { |part| part.to_s.empty? }
          parts.join(' · ') unless parts.empty?
        end
        private_class_method :credits, :file_facts, :present
      end
      # Below this many terminal rows the bar would crowd the lists out.
      TALL_MIN_SCREEN_ROWS = 30
      # Columns per spectrum band, and the most of the bar it may take.
      BAND_WIDTH = 2
      MAX_SPECTRUM_FRACTION = 3
      FILLED = '━'
      EMPTY = '─'
      private_constant :TALL_MIN_SCREEN_ROWS, :BAND_WIDTH, :MAX_SPECTRUM_FRACTION, :FILLED, :EMPTY

      # `rows`: the tall bar's inner rows (ui.player_bar_rows).
      def initialize(glyphs:, rows:)
        @glyphs = glyphs
        @rows = rows
      end

      attr_writer :rows

      # Terminal rows the bar takes, border included.
      def height(screen_rows) = screen_rows >= TALL_MIN_SCREEN_ROWS ? @rows + 2 : 1

      # Draws inside the given rectangle (inside the border, for a tall bar).
      # With `art`, the left square is left blank for the album art and
      # returned as its region; otherwise returns nil.
      # rubocop:disable Naming/MethodParameterName -- Screen's x/y convention
      def render(screen, x:, y:, w:, h:, state:, levels:, theme:, details: nil, art: false, active: false)
        return if w <= 0 || h <= 0
        return render_compact(screen, x, y, w, state, levels, theme, details, active) if h == 1

        spectrum_w = spectrum_width(levels, w)
        draw_spectrum(screen, x + w - spectrum_w, y, spectrum_w, h, levels, theme) if spectrum_w.positive?
        region = { x: x + 1, y: y, w: h * 2, h: h } if art
        text_x = region ? region[:x] + region[:w] + 1 : x + 1
        text_right = spectrum_w.positive? ? x + w - spectrum_w - 1 : x + w
        h.times { |row| screen.put(y + row, text_right, '│', fg: theme[:text_muted]) } if spectrum_w.positive?
        text_w = text_right - text_x - 1
        info_lines(state, details, h).each_with_index do |line, row|
          draw_line(screen, text_x, y + row, text_w, line, state, details, theme)
        end
        region
      end

      private

      # Title on top and progress on the bottom row; credits and file facts fill
      # the rows between while they fit (nil rows stay blank).
      def info_lines(state, details, rows)
        middle = %i[credits file_facts].select { |kind| state[:track] && details&.public_send(kind) }
                                       .first(rows - 2)
        [:title, *middle, *Array.new(rows - 2 - middle.size), :progress]
      end

      def draw_line(screen, x, y, w, kind, state, details, theme)
        return if w <= 0

        case kind
        when :title then draw_title(screen, x, y, w, state, details, theme)
        when :credits then screen.put(y, x, details.credits[0, w], fg: theme[:text])
        when :file_facts then screen.put(y, x, details.file_facts[0, w], fg: theme[:text_muted])
        when :progress then draw_progress(screen, x, y, w, state, theme)
        end
      end

      def draw_title(screen, x, y, w, state, details, theme)
        title, color = title_text(state, theme)
        right = [stars(details), state_text(state)].compact.join('  ')
        right = '' if right.size + 2 > w
        screen.put(y, x, title[0, w - right.size - (right.empty? ? 0 : 2)], fg: color, bold: true)
        screen.put(y, x + w - right.size, right, fg: theme[:accent]) unless right.empty?
      end

      def title_text(state, theme)
        if state[:focus_sound] then ["Focus — #{state[:focus_sound].title}", theme[:primary]]
        elsif state[:track] then [state[:track].title.to_s, theme[:primary]]
        else ['Nothing playing', theme[:text_muted]]
        end
      end

      # Unrated tracks say so: the bar is where the playing track is rated.
      def stars(details)
        return unless details

        details.rating ? @glyphs['star'] * details.rating : 'unrated'
      end

      def state_text(state)
        return 'queue paused' if state[:focus_sound]
        return unless state[:track]

        state[:paused] ? "#{@glyphs['pause']} paused" : "#{@glyphs['play']} playing"
      end

      # Focus sounds never end, so they show ∞ instead of a bar.
      def draw_progress(screen, x, y, w, state, theme)
        return screen.put(y, x, '∞'[0, w], fg: theme[:text_muted]) if state[:focus_sound]
        return unless state[:track]

        track = state[:track]
        duration = track.display_duration_ms
        position = state[:position_ms]
        duration_text = "#{'~' if track.planned_duration?}#{fmt(duration)}"
        time = " #{fmt(position)} / #{duration_text}"
        bar_w = w - time.size
        return screen.put(y, x, time.strip[0, w], fg: theme[:text]) if bar_w < 4

        filled = duration.to_i.positive? ? (position.to_i * bar_w / duration).clamp(0, bar_w) : 0
        screen.put(y, x, FILLED * filled, fg: theme[:accent]) if filled.positive?
        screen.put(y, x + filled, EMPTY * (bar_w - filled), fg: theme[:text_muted])
        screen.put(y, x + bar_w, time, fg: theme[:text])
      end

      # Each band is a column of eighth blocks; a band at full level fills
      # every row. Bands shrink to one column, then drop, when space is short.
      def spectrum_width(levels, w)
        return 0 if levels.empty?

        limit = w / MAX_SPECTRUM_FRACTION
        [levels.size * BAND_WIDTH, levels.size, limit].find { |width| width <= limit } || limit
      end

      def draw_spectrum(screen, x, y, w, h, levels, theme)
        ramp = @glyphs['eq_chars']
        steps = ramp.size - 1
        band_w = w >= levels.size * BAND_WIDTH ? BAND_WIDTH : 1
        bands = levels.first(w / band_w)
        h.times do |row|
          from_bottom = h - 1 - row
          cells = bands.map do |level|
            fill = ((level.clamp(0.0, 1.0) * h * steps).round - (from_bottom * steps)).clamp(0, steps)
            ramp[fill] * band_w
          end
          screen.put(y + row, x, cells.join, fg: theme[:success])
        end
      end

      # One line: title, artist, rating, and time, with the old one-row
      # spectrum at the right.
      def render_compact(screen, x, y, w, state, levels, theme, details, active)
        bars = levels.map { |level| @glyphs['eq_chars'][(level.clamp(0.0, 1.0) * (@glyphs['eq_chars'].size - 1)).round] }
                     .join[0, w / MAX_SPECTRUM_FRACTION].to_s
        text = compact_text(state, details)
        text_w = [w - bars.size - (bars.empty? ? 0 : 1), 0].max
        color = state[:track] || state[:focus_sound] ? theme[:primary] : theme[:text_muted]
        bg = theme[:selection_bg] if active
        screen.put(y, x, text[0, text_w].ljust(active ? text_w : 0), fg: active ? theme[:selection_text] : color,
                                                                     bg: bg, bold: true)
        screen.put(y, x + w - bars.size, bars, fg: theme[:success]) unless bars.empty?
      end

      def compact_text(state, details)
        return "Focus — #{state[:focus_sound].title} ∞ queue paused" if state[:focus_sound]

        track = state[:track]
        return "#{@glyphs['pause']} Nothing playing" unless track

        icon = state[:paused] ? @glyphs['pause'] : @glyphs['play']
        artist = track.artist ? " — #{track.artist}" : ''
        rating = stars(details)
        duration = "#{'~' if track.planned_duration?}#{fmt(track.display_duration_ms)}"
        parts = ["#{icon} #{track.title}#{artist}", rating, "#{fmt(state[:position_ms])}/#{duration}"]
        parts.compact.join('  ')
      end

      def fmt(milliseconds) = DurationFormatter.format(milliseconds, unknown: '?:??')
      # rubocop:enable Naming/MethodParameterName
    end
  end
end
