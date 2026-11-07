# frozen_string_literal: true

module RubyPlayer
  module UI
    # Keyboard-driven view of the session's independent output effects.
    class EffectsModal
      MAX_WIDTH_CELLS = 45
      # Border and title above the list, hint and border below.
      CHROME_ROWS = 4
      MIN_SIZE_CELLS = 4
      # Text inset from each side: border plus one blank cell.
      TEXT_INSET_CELLS = 2

      attr_reader :selection

      def initialize(rack)
        @rack = rack
        @selection = 0
        @scroll = 0
      end

      # App closes the panel on its keymap's show_effects binding; this
      # handles only the panel's own fixed controls.
      def handle_key(key)
        case key
        when 'up' then @selection = [@selection - 1, 0].max
        when 'down' then @selection = [@selection + 1, @rack.effects.size - 1].min
        when 'left' then @rack.decrease(@selection)
        when 'right' then @rack.increase(@selection)
        when 'enter' then @rack.toggle(@selection)
        when 'b' then @rack.toggle_bypass
        when 'escape' then return :close
        end
        nil
      end

      def render(screen, theme:, frame:)
        width = [screen.cols, MAX_WIDTH_CELLS].min
        # One spare row below the list keeps the hint off the last effect.
        height = [screen.rows, @rack.effects.size + CHROME_ROWS + 1].min
        return if width < MIN_SIZE_CELLS || height < MIN_SIZE_CELLS

        visible_rows = [height - CHROME_ROWS, 1].max
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
            screen.put(y + 1 + row, x + TEXT_INSET_CELLS, text[0, width - (2 * TEXT_INSET_CELLS)],
                       fg: fg, bg: bg, bold: selected)
          end
        end
      end
    end
  end
end
