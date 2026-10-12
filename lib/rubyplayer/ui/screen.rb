# frozen_string_literal: true

module RubyPlayer
  module UI
    # Value equality (Struct#==) is what makes the front/back diff in Screen#flush
    # work with a plain `!=` comparison per cell -- no custom comparator needed.
    Cell = Struct.new(:ch, :fg, :bg, :bold, :italic, :underline, :dim)
    BLANK = Cell.new(' ', nil, nil, false, false, false, false).freeze

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

      # Distinct styles seen before the cell cache starts over; themes use a
      # few dozen, so this only bounds pathological callers.
      MAX_CACHED_STYLES = 1_024

      def initialize(out:, rows:, cols:)
        @out = out
        @cell_cache = {}
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

        # Cells are never mutated once placed, so one frozen cell per distinct
        # character and style is shared across positions and frames: full-
        # screen pages redrawn at the frame rate would otherwise allocate a
        # cell per character per frame.
        cells = styled_cells(fg, bg, bold, italic, underline, dim)
        text.each_char.with_index do |ch, i|
          c = col + i
          next if c.negative?
          break if c >= @cols

          @back[row][c] = cells[ch] ||= Cell.new(ch, fg, bg, bold, italic, underline, dim).freeze
        end
      end

      def styled_cells(*style)
        @cell_cache.clear if @cell_cache.size >= MAX_CACHED_STYLES && !@cell_cache.key?(style)
        @cell_cache[style] ||= {}
      end
      private :styled_cells

      # Same result as put(row, col, ch * width, ...), but one shared cell and
      # one Array#fill instead of a per-character loop: full-screen modals
      # clear their whole surface every frame.
      def fill(row, col, width, ch: ' ', **style)
        return if row.negative? || row >= @rows

        start = [col, 0].max
        stop = [col + width, @cols].min
        return if stop <= start

        cell = Cell.new(ch, style[:fg], style[:bg], style.fetch(:bold, false), style.fetch(:italic, false),
                        style.fetch(:underline, false), style.fetch(:dim, false)).freeze
        @back[row].fill(cell, start, stop - start)
      end

      # Diffs back vs front row by row. Each contiguous run of changed cells in a
      # row gets a single cursor-position escape, then styled runs are coalesced:
      # we only emit a new SGR sequence when the style actually changes, so a run
      # of same-styled characters costs one escape instead of one per cell.
      def flush
        out = +''
        last_style = :none
        @damage = {}
        @rows.times do |r|
          c = 0
          while c < @cols
            if @front && @front[r][c] == @back[r][c]
              c += 1
              next
            end
            out << "\e[#{r + 1};#{c + 1}H"
            run_start = c
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
            record_damage(r, run_start, c - 1)
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

      # Whether the most recent flush repainted any cell inside the given
      # rectangle. Exists for overlays that live outside the cell model
      # (iTerm2 inline images): repainting cells under an image erases that
      # part of it, so its owner must re-emit — but only then, since
      # re-emitting every frame would make the image flicker. Damage is
      # per-row col ranges rather than one bounding box: two distant small
      # changes would otherwise "damage" everything between them and force
      # spurious re-emits.
      def region_damaged?(rows:, cols:)
        return false unless @damage

        rows.any? do |row|
          @damage[row]&.any? { |lo, hi| lo <= cols.last && hi >= cols.first }
        end
      end

      private

      def record_damage(row, col_start, col_end)
        return if col_end < col_start

        (@damage[row] ||= []) << [col_start, col_end]
      end

      def blank_buffer
        # put replaces cells; the immutable blank can be shared across slots.
        Array.new(@rows) { Array.new(@cols, BLANK) }
      end

      def sgr(cell)
        codes = ['0']
        codes << '1' if cell.bold
        codes << '2' if cell.dim
        codes << '3' if cell.italic
        codes << '4' if cell.underline
        codes << color_code(cell.fg, foreground: true) if cell.fg
        codes << color_code(cell.bg, foreground: false) if cell.bg
        "\e[#{codes.join(';')}m"
      end

      def color_code(color, foreground:)
        if color.is_a?(String) && color.start_with?('#')
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
