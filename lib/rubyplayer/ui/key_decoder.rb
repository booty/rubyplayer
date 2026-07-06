module RubyPlayer
  module UI
    # Normalizes raw terminal bytes into Keymap key-name strings.
    module KeyDecoder
      ESC_SEQS = { "[A" => "up", "[B" => "down", "[C" => "right", "[D" => "left",
                   "[5~" => "pgup", "[6~" => "pgdn",
                   # xterm-style modifier encoding: "1;2" = shift
                   "[1;2A" => "shift_up", "[1;2B" => "shift_down" }.freeze

      def self.decode(bytes)
        keys = []
        i = 0
        while i < bytes.length
          ch = bytes[i]
          if ch == "\e"
            if bytes[i + 1] == "["
              seq_end = i + 2
              seq_end += 1 while seq_end < bytes.length && !bytes[seq_end].match?(/[a-zA-Z~]/)
              seq = bytes[(i + 1)..seq_end]
              keys << ESC_SEQS[seq] if ESC_SEQS[seq] # paste markers & unknown seqs: dropped
              i = seq_end + 1
            else
              keys << "escape"
              i += 1
            end
          elsif ch == "\r" || ch == "\n" then keys << "enter"; i += 1
          elsif ch == "\t" then keys << "tab"; i += 1
          elsif ch == " " then keys << "space"; i += 1
          elsif ch == "\u007F" then keys << "backspace"; i += 1
          elsif ch.ord < 32 then keys << "ctrl_#{(ch.ord + 96).chr}"; i += 1
          else keys << ch; i += 1
          end
        end
        keys
      end
    end
  end
end
