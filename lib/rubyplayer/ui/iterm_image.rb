module RubyPlayer
  module UI
    # iTerm2 inline-image escape (OSC 1337 File=). The terminal does all
    # decoding (JPEG/PNG/GIF) and scaling itself: width/height are given in
    # character cells and preserveAspectRatio keeps the terminal from
    # stretching, so no image-processing dependency is needed on our side.
    module ItermImage
      def self.supported?(env = ENV)
        # LC_TERMINAL is iTerm2's own ssh story: TERM_PROGRAM doesn't cross
        # ssh, but LC_* commonly survives via AcceptEnv.
        env["TERM_PROGRAM"] == "iTerm.app" || env["LC_TERMINAL"] == "iTerm2"
      end

      def self.escape(bytes, width:, height:)
        encoded = [bytes].pack("m0")
        # size= lets iTerm2 pre-allocate; inline=1 renders at the cursor
        # instead of offering a download.
        "\e]1337;File=inline=1;size=#{bytes.bytesize};" \
          "width=#{width};height=#{height};preserveAspectRatio=1:#{encoded}\a"
      end

      # row/col are 0-based screen cells (matching Screen#put); ANSI cursor
      # addressing is 1-based, hence the +1s.
      def self.place(bytes, row:, col:, width:, height:)
        "\e[#{row + 1};#{col + 1}H#{escape(bytes, width: width, height: height)}"
      end
    end
  end
end
