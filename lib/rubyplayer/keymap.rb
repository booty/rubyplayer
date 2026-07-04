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
        ">" => "next_track", "[" => "seek_back", "]" => "seek_forward",
        "x" => "remove_from_queue",
      },
      "library" => {
        "up" => "nav_up", "down" => "nav_down",
        "left" => "collapse", "right" => "expand",
        # Overrides the global "x" => remove_from_queue binding while the
        # Library pane is focused (pane-local bindings win, see #action_for).
        "x" => "remove_library_item",
      },
      # Matching is case-insensitive (see #action_for), so "t"/"g" here also
      # match "T"/"G" from the terminal. sort_number/sort_artist use "#"/"@"
      # rather than "n"/"a" -- those letters are already global bindings
      # (enqueue_end/add_path), and case-folding would otherwise make the
      # pane-local sort binding shadow them whenever Tracks is focused.
      "tracks" => {
        "up" => "nav_up", "down" => "nav_down",
        "g" => "toggle_group",
        "t" => "sort_title", "#" => "sort_number", "@" => "sort_artist",
        "i" => "show_track_info",
      },
    }.freeze

    def initialize(config_keymap = {})
      @map = DEFAULTS.to_h do |scope, keys|
        overrides = ((config_keymap || {})[scope] || {}).transform_keys { |k| k.to_s.downcase }
        [scope, keys.merge(overrides)]
      end
    end

    # Case-insensitive: the terminal reports Shift-modified letters as their
    # uppercase form, but rubyplayer has no shift-sensitive bindings, so a
    # key should fire the same action regardless of case (displayed
    # uppercase in the UI -- see HotkeyLine).
    def action_for(key, pane:)
      key = key.downcase
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
