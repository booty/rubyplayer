module RubyPlayer
  # Maps normalized key names (already translated from tty-reader key events by
  # the App, Task 20) to action symbols. Defaults below are vim-ish but
  # deliberately avoid Cmd combos and ctrl_z, which don't survive most
  # terminals reliably (spec §9).
  class Keymap
    DEFAULTS = {
      "global" => {
        "tab" => "cycle_pane",
        "space" => "toggle_play",
        "enter" => "play_now",
        "q" => "enqueue_front",
        "n" => "enqueue_end",
        "p" => "select_queue",
        "u" => "undo",
        "ctrl_r" => "redo",
        "s" => "toggle_skip_disliked",
        "a" => "add_path",
        "0" => "rate_0", "1" => "rate_1", "2" => "rate_2", "3" => "rate_3",
        "4" => "rate_4", "5" => "rate_5", "6" => "rate_6",
        "ctrl_c" => "quit",
      },
      "library" => {
        "up" => "nav_up", "down" => "nav_down",
        "left" => "collapse", "right" => "expand",
      },
      # Sort bindings are UPPERCASE so their lowercase counterparts stay free
      # for the global map (e.g. "n" => enqueue_end vs "N" => sort_number).
      "tracks" => {
        "up" => "nav_up", "down" => "nav_down",
        "G" => "toggle_group",
        "T" => "sort_title", "N" => "sort_number", "A" => "sort_artist",
      },
    }.freeze

    def initialize(config_keymap = {})
      @map = DEFAULTS.to_h do |scope, keys|
        [scope, keys.merge((config_keymap || {})[scope] || {})]
      end
    end

    def action_for(key, pane:)
      # Pane-local bindings win over global; fall back to global when the
      # pane has no entry for this key at all.
      action = @map[pane.to_s]&.[](key) || @map["global"][key]
      action&.to_sym
    end

    def bindings_for(pane)
      local = @map[pane.to_s] || {}
      seen = {}
      # Pane-local entries first (for hotkey-line ordering), then global,
      # deduped by key so a pane override doesn't also show its global twin.
      (local.to_a + @map["global"].to_a).filter_map do |key, action|
        next if seen[key]

        seen[key] = true
        [key, action.to_sym]
      end
    end
  end
end
