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

        def next_id
          @id_mutex ||= Mutex.new
          @id_mutex.synchronize do
            @next_id = (@next_id || (Process.pid * 10_000)) + 1
          end
        end
      end

      # cell_size returns the terminal's measured [width, height] in pixels,
      # or nil when unknown. cell_aspect (height / width) is the guess used
      # then; with neither, the image fills its whole region.
      def initialize(output:, cell_size: -> {}, cell_aspect: -> {})
        @output = output
        @measured_cell_size = cell_size
        @cell_aspect = cell_aspect
        @image_id = nil
        @placement_id = nil
        @bytes = nil
        @placement = nil
      end

      # [width, height] of a cell in pixels, measured or guessed; nil when
      # neither is available. Callers size regions to the art with it.
      def cell_size
        measured = @measured_cell_size.call
        return measured if measured

        aspect = @cell_aspect.call
        [1, aspect] if aspect.is_a?(Numeric) && aspect.positive?
      end

      # Region rows that let bytes span width columns edge to edge (gap
      # aside), or nil when the image or cell size is unknown.
      def rows_to_fill(bytes, width:, gap:)
        image = self.class.png_size(bytes)
        cell = cell_size
        return nil unless image && cell

        _pad_cols, pad_rows, room_cols, = room(width, Float::INFINITY, gap, cell)
        rows_for(room_cols, image, cell) + (2 * pad_rows)
      end

      # row and col are 0-based terminal cells. gap is the visual distance,
      # in cell widths, between the art and a border line drawn through the
      # neighboring cells; align :bottom puts spare rows above the art. A
      # bad region must not leave an old placement visible elsewhere.
      def render(bytes, row:, col:, width:, height:, gap: 0, align: :center, force: false)
        unless valid_region?(bytes, row, col, width, height)
          hide
          return nil
        end

        placement = [row, col, width, height, gap, align, cell_size]
        return nil if !force && bytes == @bytes && placement == @placement

        if bytes != @bytes
          clear
          @bytes = bytes
          @image_id = self.class.send(:next_id)
          @placement_id = self.class.send(:next_id)
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

      def valid_region?(bytes, row, col, width, height)
        bytes.is_a?(String) && bytes.start_with?(PNG_SIGNATURE) &&
          [row, col, width, height].all?(Integer) &&
          row >= 0 && col >= 0 && width.positive? && height.positive?
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
        row, col, width, height, gap, align, cell = placement
        fit = fit_box(width, height, gap, align, cell)
        keys = if fit
                 cols, rows, row_shift, col_shift, source = fit
                 row += row_shift
                 col += col_shift
                 "#{source}c=#{cols},r=#{rows}"
               else
                 "c=#{width},r=#{height}"
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
      def fit_box(width, height, gap, align, cell)
        image = self.class.png_size(@bytes)
        return nil unless image && cell

        image_w, image_h = image
        cell_w, cell_h = cell
        _pad_cols, pad_rows, room_cols, room_rows = room(width, height, gap, cell)
        cols = room_cols
        rows = rows_for(cols, image, cell)
        if rows > room_rows
          rows = room_rows
          cols = even_spare_cols((rows * cell_h * image_w).fdiv(image_h * cell_w), width, room_cols)
        end
        crop = source_crop(image_w, image_h, (cols * cell_w).fdiv(rows * cell_h))
        row_shift = align == :bottom ? height - rows - pad_rows : (height - rows) / 2
        [cols, rows, row_shift, (width - cols) / 2, crop]
      end

      # Padding per side in whole cells, plus the cells left inside it.
      # Border lines run through the middle of their cells, so half a cell
      # of gap already exists and only the remainder needs padding. Rows
      # are the coarser step, so the bottom takes the nearest row count and
      # the sides then take the column count that best matches it.
      def room(width, height, gap, cell)
        cell_w, cell_h = cell
        target = gap * cell_w
        if target.positive?
          pad_rows = ([target - (cell_h / 2.0), 0].max / cell_h).round
          bottom_gap = (pad_rows * cell_h) + (cell_h / 2.0)
          pad_cols = ([bottom_gap - (cell_w / 2.0), 0].max / cell_w).round
        else
          pad_rows = pad_cols = 0
        end
        # Padding that would leave less than a cell is dropped, not honored.
        pad_cols = 0 if width - (2 * pad_cols) < 1
        pad_rows = 0 if height - (2 * pad_rows) < 1
        [pad_cols, pad_rows, width - (2 * pad_cols), height - (2 * pad_rows)]
      end

      # Column count nearest ideal whose leftover splits evenly, so the
      # side gaps match; an odd leftover puts a whole extra cell on one side.
      def even_spare_cols(ideal, width, limit)
        (1..limit).select { |cols| (width - cols).even? }.min_by { |cols| (cols - ideal).abs } ||
          ideal.round.clamp(1, limit)
      end

      def rows_for(cols, image, cell)
        image_w, image_h = image
        (cols * cell[0] * image_h).fdiv(image_w * cell[1]).round.clamp(1, nil)
      end

      def source_crop(image_w, image_h, box_aspect)
        crop_w = [(image_h * box_aspect).round, image_w].min
        crop_h = [(image_w / box_aspect).round, image_h].min
        return '' if crop_w == image_w && crop_h == image_h

        "x=#{(image_w - crop_w) / 2},y=#{(image_h - crop_h) / 2},w=#{crop_w},h=#{crop_h},"
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
