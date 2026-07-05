module RubyPlayer
  # Safe interpolation of track-display format strings from config.
  # Whitelist only — a config typo or hostile string can never execute code.
  class Template
    # Any brace content is captured (not just identifier chars) so that
    # non-whitelisted junk like "{system('rm -rf /')}" is still routed through
    # field_value's whitelist dispatch and rendered empty, rather than passed
    # through untouched as literal text.
    TOKEN = /\{([^{}]*)\}/

    def initialize(format_string, star_glyph: "★")
      @star = star_glyph
      # Alternating literal / field parts, parsed once.
      @parts = format_string.to_s.split(TOKEN).each_with_index.map do |part, i|
        i.odd? ? { field: part } : { literal: part }
      end
    end

    def render(track, album_artist: nil)
      out = @parts.map do |part|
        part.key?(:literal) ? part[:literal] : field_value(part[:field], track, album_artist)
      end.join
      out.gsub(/\s+/, " ").strip
    end

    # Same rendering as #render, but keeps each field's name attached to its
    # text instead of joining into one string -- callers that style fields
    # differently (bold title, italic artist, ...) need to know which run of
    # characters came from which field.
    def render_segments(track, album_artist: nil)
      raw = @parts.map do |part|
        if part.key?(:literal)
          { text: part[:literal], field: nil }
        else
          { text: field_value(part[:field], track, album_artist), field: part[:field] }
        end
      end
      normalize_segments(raw)
    end

    private

    # Mirrors #render's `gsub(/\s+/, " ").strip`, but on the segment list
    # rather than the joined string, so surviving segments keep their field.
    # A hidden field (e.g. {artist?} matching the album's own artist)
    # renders empty and must not leave a stray double space behind.
    def normalize_segments(raw)
      out = raw.reject { |s| s[:field] && s[:text].empty? }.each_with_object([]) do |seg, kept|
        blank = seg[:field].nil? && seg[:text].strip.empty?
        prev_blank = kept.last && kept.last[:field].nil? && kept.last[:text].strip.empty?
        kept << seg unless blank && prev_blank
      end
      out.shift while out.first && out.first[:field].nil? && out.first[:text].strip.empty?
      out.pop while out.last && out.last[:field].nil? && out.last[:text].strip.empty?
      out
    end

    def field_value(field, track, album_artist)
      case field
      when "title"        then track.title.to_s
      when "album"        then track.album.to_s
      when "artist"       then track.artist.to_s
      when "artist?"      then track.artist == album_artist ? "" : track.artist.to_s
      when "composer"     then track.composer.to_s
      when "format"       then track.format.to_s
      when "track_number" then track.track_number ? format("%02d", track.track_number) : ""
      when "duration"     then duration(track.duration_ms)
      when "rating"       then track.rating ? @star * track.rating : ""
      else "" # unknown field: render nothing, never fail
      end
    end

    def duration(ms)
      return "" unless ms
      total = ms / 1000
      format("%d:%02d", total / 60, total % 60)
    end
  end
end
