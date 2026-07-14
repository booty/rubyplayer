module RubyPlayer
  class TrackFormatter
    Fragment = Data.define(:text, :style)

    STYLE_KEYS = %i[fg bg bold italic underline dim].freeze
    BOOLEAN_STYLES = %i[bold italic underline dim].freeze
    ANSI_COLORS = %i[
      black red green yellow blue magenta cyan white
      bright_black bright_red bright_green bright_yellow bright_blue
      bright_magenta bright_cyan bright_white
    ].freeze
    THEME_ROLES = Theme::DEFAULT.keys.reject { |key| %i[name mode].include?(key) }.freeze

    class Context
      attr_reader :album_artist

      def initialize(album_artist:, star_glyph:)
        @album_artist = album_artist
        @star_glyph = star_glyph
      end

      def text(value, **style)
        return nil if value.nil? || value.to_s.empty?

        TrackFormatter.fragment(value.to_s, style)
      end

      def number(value, width: 2, **style)
        return nil if value.nil?

        text(format("%0*d", width, Integer(value)), **style)
      end

      def duration(milliseconds, **style)
        return nil if milliseconds.nil?

        total = Integer(milliseconds) / 1000
        text(format("%d:%02d", total / 60, total % 60), **style)
      end

      def stars(rating, **style)
        return nil if rating.nil?

        text(@star_glyph * Integer(rating), **style)
      end

      def line(*parts, separator: " ")
        kept = parts.flat_map { |part| TrackFormatter.normalize(part) }
        kept.each_with_index.flat_map do |part, index|
          index.zero? ? [part] : [TrackFormatter.fragment(separator, {}), part]
        end
      end
    end

    class << self
      def render(formatter, track, album_artist: nil, star_glyph: "★")
        context = Context.new(album_artist: album_artist, star_glyph: star_glyph)
        normalize(formatter.call(track, context)).map do |fragment|
          { text: fragment.text, **STYLE_KEYS.to_h { |key| [key, fragment.style[key]] } }.freeze
        end.freeze
      rescue ConfigError
        raise
      rescue StandardError => error
        raise ConfigError.new(path: "<track formatter>", original: error), cause: error
      end

      def fragment(text, style)
        unknown = style.keys - STYLE_KEYS
        raise ConfigError.new(path: "<track formatter>",
                              message: "unknown formatter style #{unknown.first.inspect}") unless unknown.empty?

        BOOLEAN_STYLES.each do |key|
          value = style[key]
          next if value.nil? || value == true || value == false

          raise ConfigError.new(path: "<track formatter>",
                                message: "#{key} must be true or false")
        end
        %i[fg bg].each { |key| validate_color!(style[key]) if style[key] }
        Fragment.new(text.to_s.freeze, style.dup.freeze).freeze
      end

      def normalize(value)
        case value
        when nil then []
        when String then value.empty? ? [] : [fragment(value, {})]
        when Fragment then value.text.empty? ? [] : [value]
        when Array then value.flat_map { |child| normalize(child) }
        else
          raise ConfigError.new(
            path: "<track formatter>",
            message: "formatter returned unsupported #{value.class}; expected String, fragment, or Array"
          )
        end
      end

      private

      def validate_color!(color)
        valid = if color.is_a?(Symbol)
                  ANSI_COLORS.include?(color) || THEME_ROLES.include?(color)
                else
                  color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{6}\z/)
                end
        return if valid

        raise ConfigError.new(path: "<track formatter>",
                              message: "unsupported formatter color #{color.inspect}")
      end
    end
  end
end
