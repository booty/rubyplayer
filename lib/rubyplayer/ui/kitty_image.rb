# frozen_string_literal: true

module RubyPlayer
  module UI
    # Owns one Kitty graphics image and its current screen placement. The
    # terminal retains uploaded pixels across ordinary repaints and moves.
    class KittyImage
      MAX_CHUNK_BYTES = 4096
      PNG_SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze
      MIN_ITERM_VERSION = [3, 5, 4].freeze

      class << self
        def supported?(env = ENV)
          return false if env['TMUX'] || env['STY']

          kitty_window = !env['KITTY_WINDOW_ID'].to_s.empty?
          return true if env['TERM'] == 'xterm-kitty' || env['TERM_PROGRAM'] == 'kitty' || kitty_window

          iterm_supported?(env)
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

      def initialize(output:)
        @output = output
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

        placement = [row, col, width, height]
        return nil if !force && bytes == @bytes && placement == @placement

        if bytes != @bytes
          clear
          @bytes = bytes
          @image_id = self.class.send(:next_id)
          @placement_id = self.class.send(:next_id)
          transmit(bytes)
        end

        place(row, col, width, height)
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

      def place(row, col, width, height)
        @placement = [row, col, width, height]
        command = "\e_Ga=p,i=#{@image_id},p=#{@placement_id},c=#{width},r=#{height},C=1,q=2\e\\"
        write("\e[s\e[#{row + 1};#{col + 1}H#{command}\e[u")
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
