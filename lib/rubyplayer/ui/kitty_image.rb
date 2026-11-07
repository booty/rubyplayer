# frozen_string_literal: true

module RubyPlayer
  module UI
    # Owns one Kitty graphics image and its current screen placement. The
    # terminal retains uploaded pixels across ordinary repaints and moves.
    class KittyImage
      MAX_CHUNK_BYTES = 4096
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      MIN_ITERM_VERSION = [3, 5, 4].freeze
      # struct winsize request: rows, cols, xpixel, ypixel as unsigned shorts.
      TIOCGWINSZ = RUBY_PLATFORM.include?('darwin') ? 0x40087468 : 0x5413

      class << self
        def supported?(env = ENV)
          return false if env['TMUX'] || env['STY']

          kitty?(env) || iterm_supported?(env)
        end

        # [width, height] of one cell in pixels, from the terminal's own
        # winsize report. nil when the terminal leaves the pixel fields zero.
        def tty_cell_size(io = IO.console)
          return nil unless io

          buf = [0, 0, 0, 0].pack('S4')
          io.ioctl(TIOCGWINSZ, buf)
          rows, cols, xpixel, ypixel = buf.unpack('S4')
          return nil unless [rows, cols, xpixel, ypixel].all?(&:positive?)

          [xpixel.fdiv(cols), ypixel.fdiv(rows)]
        rescue SystemCallError, NotImplementedError
          nil
        end

        # Image and placement ids are unique per process (and, offset by pid,
        # across processes sharing a terminal).
        def next_id
          @id_mutex ||= Mutex.new
          @id_mutex.synchronize do
            @next_id = (@next_id || (Process.pid * 10_000)) + 1
          end
        end

        # Width and height from the PNG IHDR chunk, which always comes first.
        def png_size(bytes)
          return nil unless bytes.is_a?(String) && bytes.bytesize >= 24 && bytes.byteslice(12, 4) == 'IHDR'

          dims = bytes.byteslice(16, 8).unpack('NN')
          dims.all?(&:positive?) ? dims : nil
        end

        private

        def kitty?(env)
          env['TERM'] == 'xterm-kitty' || env['TERM_PROGRAM'] == 'kitty' || !env['KITTY_WINDOW_ID'].to_s.empty?
        end

        def iterm_supported?(env)
          version = if env['TERM_PROGRAM'] == 'iTerm.app'
                      env['TERM_PROGRAM_VERSION']
                    elsif env['LC_TERMINAL'] == 'iTerm2'
                      env['LC_TERMINAL_VERSION']
                    end
          parts = version&.match(/\A(\d+)\.(\d+)\.(\d+)\z/)
          return false unless parts

          (parts.captures.map(&:to_i) <=> MIN_ITERM_VERSION) >= 0
        end
      end

      # Where and how an image sits: a cell region plus the cell size it was
      # fitted with, so a font-size change refits even at the same region.
      Placement = Data.define(:row, :col, :width_cells, :height_cells, :gap_cells, :align, :cell_size_px)
      # Whole-cell padding per side, and the cells left inside it.
      Room = Data.define(:pad_cols, :pad_rows, :cols, :rows)
      # The box the image is stretched over, its offset inside the region,
      # and the Kitty source-crop keys that keep its aspect ratio.
      Fit = Data.define(:cols, :rows, :row_shift, :col_shift, :crop_keys)

      # measured_cell_size_px returns the terminal's measured [width, height]
      # in pixels, or nil when unknown. cell_aspect (height / width) is the
      # guess used then; with neither, the image fills its whole region.
      def initialize(output:, measured_cell_size_px: -> {}, cell_aspect: -> {})
        @output = output
        @measured_cell_size_px = measured_cell_size_px
        @cell_aspect = cell_aspect
        @image_id = nil
        @placement_id = nil
        @bytes = nil
        @placement = nil
      end

      # [width, height] of a cell in pixels, measured or guessed; nil when
      # neither is available. A guess is [1, aspect]: only the ratio is
      # known, which is all the fitting math uses. Callers size regions to
      # the art with it.
      def cell_size_px
        measured = @measured_cell_size_px.call
        return measured if measured

        aspect = @cell_aspect.call
        [1, aspect] if aspect.is_a?(Numeric) && aspect.positive?
      end

      # Region rows that let bytes span width_cells columns edge to edge
      # (gap aside), or nil when the image or cell size is unknown.
      def rows_to_fill(bytes, width_cells:, gap_cells:)
        image_size_px = self.class.png_size(bytes)
        cell_size_px = self.cell_size_px
        return nil unless image_size_px && cell_size_px

        room = room(width_cells, Float::INFINITY, gap_cells, cell_size_px)
        rows_for(room.cols, image_size_px, cell_size_px) + (2 * room.pad_rows)
      end

      # row and col are 0-based terminal cells. gap_cells is the visual
      # distance, in cell widths, between the art and a border line drawn
      # through the neighboring cells; align :bottom puts spare rows above
      # the art. A bad region must not leave an old placement visible
      # elsewhere.
      def render(bytes, row:, col:, width_cells:, height_cells:, gap_cells: 0, align: :center, force: false)
        unless valid_region?(bytes, row, col, width_cells, height_cells)
          hide
          return nil
        end

        placement = Placement.new(row: row, col: col, width_cells: width_cells, height_cells: height_cells,
                                  gap_cells: gap_cells, align: align, cell_size_px: cell_size_px)
        return nil if !force && bytes == @bytes && placement == @placement

        if bytes != @bytes
          clear
          @bytes = bytes
          @image_id = self.class.next_id
          @placement_id = self.class.next_id
          transmit(bytes)
        end

        place(placement)
        nil
      end

      # Remove the visible placement but keep pixels resident for later use.
      def hide
        delete_placement if @placement_id && @placement
        @placement = nil
        nil
      end

      # Free only this instance's placement and image data.
      def clear
        hide
        write("\e_Ga=d,d=I,i=#{@image_id},q=2\e\\") if @image_id
        @image_id = nil
        @placement_id = nil
        @bytes = nil
        @placement = nil
        nil
      end

      private

      def valid_region?(bytes, row, col, width_cells, height_cells)
        bytes.is_a?(String) && bytes.start_with?(PNG_SIGNATURE) &&
          [row, col, width_cells, height_cells].all?(Integer) &&
          row >= 0 && col >= 0 && width_cells.positive? && height_cells.positive?
      end

      def transmit(bytes)
        encoded = [bytes].pack('m0')
        chunks = encoded.scan(/.{1,#{MAX_CHUNK_BYTES}}/mo)
        chunks.each_with_index do |chunk, index|
          more = index == chunks.length - 1 ? 0 : 1
          header = if index.zero?
                     "a=t,t=d,f=100,i=#{@image_id},q=2,m=#{more}"
                   else
                     "q=2,m=#{more}"
                   end
          write("\e_G#{header};#{chunk}\e\\")
        end
      end

      def place(placement)
        @placement = placement
        row = placement.row
        col = placement.col
        fit = fit_box(placement)
        keys = if fit
                 row += fit.row_shift
                 col += fit.col_shift
                 "#{fit.crop_keys}c=#{fit.cols},r=#{fit.rows}"
               else
                 "c=#{placement.width_cells},r=#{placement.height_cells}"
               end
        command = "\e_Ga=p,i=#{@image_id},p=#{@placement_id},#{keys},C=1,q=2\e\\"
        write("\e[s\e[#{row + 1};#{col + 1}H#{command}\e[u")
      end

      # Kitty's c/r keys stretch the image over exactly that cell box in
      # iTerm2 and older Kitty, so the box itself must carry the aspect
      # ratio. Whole cells can't match it exactly; a source crop absorbs the
      # rounding (under half a cell) rather than distorting the picture.
      # X/Y sub-cell offsets are deliberately unused: iTerm2 ignores them
      # and Kitty shrinks the image by the offset instead of moving it.
      def fit_box(placement)
        image_size_px = self.class.png_size(@bytes)
        cell_size_px = placement.cell_size_px
        return nil unless image_size_px && cell_size_px

        image_width_px, image_height_px = image_size_px
        cell_width_px, cell_height_px = cell_size_px
        width_cells = placement.width_cells
        height_cells = placement.height_cells
        room = room(width_cells, height_cells, placement.gap_cells, cell_size_px)
        cols = room.cols
        rows = rows_for(cols, image_size_px, cell_size_px)
        if rows > room.rows
          rows = room.rows
          ideal_cols = (rows * cell_height_px * image_width_px).fdiv(image_height_px * cell_width_px)
          cols = even_spare_cols(ideal_cols, width_cells, room.cols)
        end
        box_aspect = (cols * cell_width_px).fdiv(rows * cell_height_px)
        row_shift = placement.align == :bottom ? height_cells - rows - room.pad_rows : (height_cells - rows) / 2
        Fit.new(cols: cols, rows: rows, row_shift: row_shift, col_shift: (width_cells - cols) / 2,
                crop_keys: source_crop(image_width_px, image_height_px, box_aspect))
      end

      # Padding per side in whole cells, plus the cells left inside it.
      # Border lines run through the middle of their cells, so half a cell
      # of gap already exists and only the remainder needs padding. Rows
      # are the coarser step, so the bottom takes the nearest row count and
      # the sides then take the column count that best matches it.
      def room(width_cells, height_cells, gap_cells, cell_size_px)
        cell_width_px, cell_height_px = cell_size_px
        target_gap_px = gap_cells * cell_width_px
        if target_gap_px.positive?
          pad_rows = ([target_gap_px - (cell_height_px / 2.0), 0].max / cell_height_px).round
          bottom_gap_px = (pad_rows * cell_height_px) + (cell_height_px / 2.0)
          pad_cols = ([bottom_gap_px - (cell_width_px / 2.0), 0].max / cell_width_px).round
        else
          pad_rows = pad_cols = 0
        end
        # Padding that would leave less than a cell is dropped, not honored.
        pad_cols = 0 if width_cells - (2 * pad_cols) < 1
        pad_rows = 0 if height_cells - (2 * pad_rows) < 1
        Room.new(pad_cols: pad_cols, pad_rows: pad_rows,
                 cols: width_cells - (2 * pad_cols), rows: height_cells - (2 * pad_rows))
      end

      # Column count nearest ideal whose leftover splits evenly, so the
      # side gaps match; an odd leftover puts a whole extra cell on one side.
      def even_spare_cols(ideal_cols, width_cells, limit_cols)
        (1..limit_cols).select { |cols| (width_cells - cols).even? }.min_by { |cols| (cols - ideal_cols).abs } ||
          ideal_cols.round.clamp(1, limit_cols)
      end

      def rows_for(cols, image_size_px, cell_size_px)
        image_width_px, image_height_px = image_size_px
        cell_width_px, cell_height_px = cell_size_px
        (cols * cell_width_px * image_height_px).fdiv(image_width_px * cell_height_px).round.clamp(1, nil)
      end

      def source_crop(image_width_px, image_height_px, box_aspect)
        crop_width_px = [(image_height_px * box_aspect).round, image_width_px].min
        crop_height_px = [(image_width_px / box_aspect).round, image_height_px].min
        return '' if crop_width_px == image_width_px && crop_height_px == image_height_px

        "x=#{(image_width_px - crop_width_px) / 2},y=#{(image_height_px - crop_height_px) / 2}," \
          "w=#{crop_width_px},h=#{crop_height_px},"
      end

      def delete_placement
        write("\e_Ga=d,d=i,i=#{@image_id},p=#{@placement_id},q=2\e\\")
      end

      def write(bytes)
        io = @output.respond_to?(:call) ? @output.call : @output
        io.write(bytes)
      end
    end
  end
end
