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

          kitty_window = !env['KITTY_WINDOW_ID'].to_s.empty?
          return true if env['TERM'] == 'xterm-kitty' || env['TERM_PROGRAM'] == 'kitty' || kitty_window

          iterm_supported?(env)
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

        private

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

      # cell_size returns [width, height] in pixels, or nil when unknown; the
      # image then fills its whole region as before.
      def initialize(output:, cell_size: -> {})
        @output = output
        @cell_size = cell_size
        @image_id = nil
        @placement_id = nil
        @bytes = nil
        @placement = nil
      end

      # row and col are 0-based terminal cells. A bad region must not leave an
      # old placement visible elsewhere on the screen.
      def render(bytes, row:, col:, width:, height:, force: false)
        unless valid_region?(bytes, row, col, width, height)
          hide
          return nil
        end

        placement = [row, col, width, height, @cell_size.call]
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
        row, col, width, height, cell = placement
        fit = fit_box(width, height, cell)
        if fit
          cols, rows, source = fit
          row += (height - rows) / 2
          col += (width - cols) / 2
          width = cols
          height = rows
        end
        keys = "a=p,i=#{@image_id},p=#{@placement_id},#{source}c=#{width},r=#{height},C=1,q=2"
        write("\e[s\e[#{row + 1};#{col + 1}H\e_G#{keys}\e\\\e[u")
      end

      # Kitty's c/r keys stretch the image over exactly that cell box in
      # iTerm2 and older Kitty, so the box itself must carry the aspect
      # ratio. Whole cells can't match it exactly; a source crop absorbs the
      # rounding (under half a cell) rather than distorting the picture.
      def fit_box(width, height, cell)
        image = image_size
        return nil unless image && cell

        image_w, image_h = image
        cell_w, cell_h = cell
        scale = [(width * cell_w).fdiv(image_w), (height * cell_h).fdiv(image_h)].min
        cols = (image_w * scale / cell_w).round.clamp(1, width)
        rows = (image_h * scale / cell_h).round.clamp(1, height)
        [cols, rows, source_crop(image_w, image_h, (cols * cell_w).fdiv(rows * cell_h))]
      end

      def source_crop(image_w, image_h, box_aspect)
        crop_w = [(image_h * box_aspect).round, image_w].min
        crop_h = [(image_w / box_aspect).round, image_h].min
        return '' if crop_w == image_w && crop_h == image_h

        "x=#{(image_w - crop_w) / 2},y=#{(image_h - crop_h) / 2},w=#{crop_w},h=#{crop_h},"
      end

      # Width and height from the PNG IHDR chunk, which always comes first.
      def image_size
        return nil unless @bytes.bytesize >= 24 && @bytes.byteslice(12, 4) == 'IHDR'

        dims = @bytes.byteslice(16, 8).unpack('NN')
        dims.all?(&:positive?) ? dims : nil
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
