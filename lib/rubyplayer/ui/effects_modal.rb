# frozen_string_literal: true

module RubyPlayer
  module UI
    # Keyboard-driven view of the session's independent output effects.
    class EffectsModal
      attr_reader :selection

      def initialize(rack)
        @rack = rack
        @selection = 0
        @scroll = 0
      end

      def handle_key(key)
        case key
        when 'up' then @selection = [@selection - 1, 0].max
        when 'down' then @selection = [@selection + 1, @rack.effects.size - 1].min
        when 'left' then @rack.adjust(@selection, -5)
        when 'right' then @rack.adjust(@selection, 5)
        when 'enter' then @rack.toggle(@selection)
        when 'b' then @rack.toggle_bypass
        when 'escape', 'd' then return :close
        end
        nil
      end

      def render(screen, theme:, frame:)
        width = [screen.cols, 45].min
        height = [screen.rows, @rack.effects.size + 5].min
        return if width < 4 || height < 4

        visible_rows = [height - 4, 1].max
        @scroll = [@scroll, @selection].min
        @scroll = [@scroll, @selection - visible_rows + 1].max
        title = @rack.bypassed? ? 'Effects — BYPASS' : 'Effects'
        hint = '[↑↓] Select [←→] Level [enter] Toggle [b] Bypass [esc] Close'
        frame.call(title: title, w: width, h: height, hint: hint) do |x, y|
          @rack.effects.drop(@scroll).first(visible_rows).each_with_index do |effect, row|
            selected = row + @scroll == @selection
            text = "#{effect.enabled ? '[x]' : '[ ]'} #{effect.name}  #{effect.intensity_percent}%"
            fg = selected ? theme[:selection_text] : theme[:text]
            bg = selected ? theme[:selection_bg] : theme[:surface]
            screen.fill(y + 1 + row, x + 1, width - 2, bg: bg)
            screen.put(y + 1 + row, x + 2, text[0, width - 4], fg: fg, bg: bg, bold: selected)
          end
        end
      end
    end
  end
end
