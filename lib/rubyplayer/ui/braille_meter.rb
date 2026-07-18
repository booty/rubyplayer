module RubyPlayer
  module UI
    # Spectrum meter drawn with braille characters: each cell is a 2x4 dot
    # grid, so a w x h cell region resolves 2w columns by 4h rows — four
    # times the vertical resolution of block glyphs, which is what makes a
    # small art region readable as a spectrum. Pure cell output: works in
    # any terminal, no iTerm2 requirement.
    module BrailleMeter
      # Unicode braille dot numbering is column-major with dots 7/8 appended
      # below (historical 6-dot legacy), hence the non-contiguous bit values
      # for the bottom row.
      DOT_BITS = [
        [0x01, 0x02, 0x04, 0x40], # left sub-column, top to bottom
        [0x08, 0x10, 0x20, 0x80], # right sub-column
      ].freeze
      BASE = 0x2800

      def self.render(screen, levels, x:, y:, w:, h:, fg:)
        return if levels.empty? || w < 1 || h < 1

        dot_cols = w * 2
        dot_rows = h * 4
        heights = Array.new(dot_cols) do |dot_col|
          # Nearest-band mapping spreads N bands across 2w columns without
          # interpolation — adjacent duplicates read fine at this scale.
          band = levels[dot_col * levels.size / dot_cols]
          (band.clamp(0.0, 1.0) * dot_rows).round
        end

        h.times do |row|
          line = +""
          w.times do |cell|
            mask = 0
            DOT_BITS.each_with_index do |bits, sub|
              column_height = heights[(cell * 2) + sub]
              bits.each_with_index do |bit, dy|
                # Columns grow upward from the region's bottom edge.
                mask |= bit if (row * 4) + dy >= dot_rows - column_height
              end
            end
            line << (BASE + mask).chr(Encoding::UTF_8)
          end
          screen.put(y + row, x, line, fg: fg)
        end
        nil
      end
    end
  end
end
