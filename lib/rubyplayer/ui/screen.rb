module RubyPlayer
  module UI
    # Value equality (Struct#==) is what makes the front/back diff in Screen#flush
    # work with a plain `!=` comparison per cell -- no custom comparator needed.
    Cell = Struct.new(:ch, :fg, :bg, :bold, :italic, :underline, :dim)
    BLANK = Cell.new(" ", nil, nil, false, false, false, false).freeze

    # Immediate-mode, double-buffered screen: views `put` into the back buffer
    # every frame, and `flush` diffs it against the front buffer (what's actually
    # on the terminal) to emit the minimal ANSI needed to reconcile the two.
    # App-agnostic -- no knowledge of panes, tracks, or layout.
    class Screen
      FG_CODES = { black: 30, red: 31, green: 32, yellow: 33, blue: 34,
                   magenta: 35, cyan: 36, white: 37,
                   bright_black: 90, bright_red: 91, bright_green: 92,
                   bright_yellow: 93, bright_blue: 94, bright_magenta: 95,
                   bright_cyan: 96, bright_white: 97 }.freeze

      attr_reader :rows, :cols

      def initialize(out:, rows:, cols:)
        @out = out
        resize(rows, cols)
      end

      # Dropping @front forces the next flush to treat every cell as changed,
      # which is exactly a full repaint -- no separate "dirty everything" path needed.
      def resize(rows, cols)
        @rows = rows
        @cols = cols
        @front = nil # force full repaint
        @back = blank_buffer
      end

      def clear_back
        @back = blank_buffer
      end

      def put(row, col, text, fg: nil, bg: nil, bold: false, italic: false,
              underline: false, dim: false)
        return if row.negative? || row >= @rows

        text.each_char.with_index do |ch, i|
          c = col + i
          next if c.negative?
          break if c >= @cols

          @back[row][c] = Cell.new(ch, fg, bg, bold, italic, underline, dim)
        end
      end

      # Diffs back vs front row by row. Each contiguous run of changed cells in a
      # row gets a single cursor-position escape, then styled runs are coalesced:
      # we only emit a new SGR sequence when the style actually changes, so a run
      # of same-styled characters costs one escape instead of one per cell.
      def flush
        out = +""
        last_style = :none
        @rows.times do |r|
          c = 0
          while c < @cols
            if @front && @front[r][c] == @back[r][c]
              c += 1
              next
            end
            out << "\e[#{r + 1};#{c + 1}H"
            while c < @cols && (@front.nil? || @front[r][c] != @back[r][c])
              cell = @back[r][c]
              style = [cell.fg, cell.bg, cell.bold, cell.italic, cell.underline, cell.dim]
              if style != last_style
                out << sgr(cell)
                last_style = style
              end
              out << cell.ch
              c += 1
            end
          end
        end
        unless out.empty?
          out << "\e[0m"
          @out.write(out)
          @out.flush if @out.respond_to?(:flush)
        end
        @front = @back.map(&:dup)
        out
      end

      private

      def blank_buffer
        Array.new(@rows) { Array.new(@cols) { BLANK.dup } }
      end

      def sgr(cell)
        codes = ["0"]
        codes << "1" if cell.bold
        codes << "2" if cell.dim
        codes << "3" if cell.italic
        codes << "4" if cell.underline
        codes << color_code(cell.fg, foreground: true) if cell.fg
        codes << color_code(cell.bg, foreground: false) if cell.bg
        "\e[#{codes.join(';')}m"
      end

      def color_code(color, foreground:)
        if color.is_a?(String) && color.start_with?("#")
          r = color[1, 2].to_i(16)
          g = color[3, 2].to_i(16)
          b = color[5, 2].to_i(16)
          "#{foreground ? 38 : 48};2;#{r};#{g};#{b}"
        else
          base = FG_CODES.fetch(color.to_sym, 37)
          (foreground ? base : base + 10).to_s
        end
      end
    end
  end
end
