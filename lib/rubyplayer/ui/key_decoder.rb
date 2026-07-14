module RubyPlayer
  module UI
    # Normalizes raw terminal bytes into Keymap key-name strings.
    module KeyDecoder
      Paste = Struct.new(:text)
      PASTE_START = "\e[200~"
      PASTE_END = "\e[201~"
      ESC_SEQS = { "[A" => "up", "[B" => "down", "[C" => "right", "[D" => "left",
                   "[5~" => "pgup", "[6~" => "pgdn",
                   # xterm-style modifier encoding: "1;2" = shift
                   "[1;2A" => "shift_up", "[1;2B" => "shift_down" }.freeze

      def self.decode(bytes)
        keys = []
        i = 0
        while i < bytes.length
          ch = bytes[i]
          # Bracketed paste must remain one event. Treating dropped path as
          # ordinary keystrokes lets leading "/" open filter and later letters
          # trigger unrelated global shortcuts.
          if bytes.byteslice(i, PASTE_START.length) == PASTE_START
            content_start = i + PASTE_START.length
            content_end = bytes.index(PASTE_END, content_start)
            if content_end
              keys << Paste.new(bytes[content_start...content_end])
              i = content_end + PASTE_END.length
            else
              i = bytes.length
            end
          elsif ch == "\e"
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
