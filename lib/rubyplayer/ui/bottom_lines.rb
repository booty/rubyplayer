module RubyPlayer
  module UI
    class PlaybackLine
      def initialize(glyphs:)
        @glyphs = glyphs
      end

      def render(screen, row:, w:, state:, levels:, theme:)
        if state[:track].nil?
          screen.put(row, 0, "#{@glyphs['pause']} stopped", fg: theme[:text_muted])
          return
        end
        t = state[:track]
        icon = state[:paused] ? @glyphs["pause"] : @glyphs["play"]
        time = "#{fmt(state[:position_ms])}/#{fmt(t.duration_ms)}"
        text = "#{icon} #{t.title}#{t.artist ? " — #{t.artist}" : ''}  #{time}"
        bars = eq_bars(levels)
        screen.put(row, 0, text[0, w - bars.size - 1], fg: theme[:primary], bold: true)
        screen.put(row, w - bars.size, bars, fg: theme[:success])
      end

      private

      def eq_bars(levels)
        chars = @glyphs["eq_chars"]
        levels.map { |l| chars[(l * (chars.size - 1)).round] }.join
      end

      def fmt(ms)
        return "?:??" unless ms
        total = ms / 1000
        format("%d:%02d", total / 60, total % 60)
      end
    end

    class StatusLine
      def initialize(seconds: 5, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @seconds = seconds
        @clock = clock
        @message = nil
        @expires_at = 0.0
      end

      def set_message(text)
        @message = text
        @expires_at = @clock.call + @seconds
      end

      def render(screen, row:, w:, default:, theme:)
        active = @message && @clock.call < @expires_at
        text = active ? @message : default
        screen.put(row, 0, text.to_s[0, w], fg: theme[:warning])
      end
    end

    class HotkeyLine
      LABELS = {
        cycle_pane: "panes", toggle_play: "play/pause", play_now: "play now",
        enqueue_front: "queue next", enqueue_end: "queue last", select_queue: "queue",
        undo: "undo", redo: "redo", toggle_skip_disliked: "skip 1-star", add_path: "add",
        quit: "quit", nav_up: nil, nav_down: nil, collapse: nil, expand: nil,
        nav_page_up: nil, nav_page_down: nil,
        toggle_group: "group", sort_title: "title", sort_number: "number",
        sort_artist: "artist",
        next_track: "next", seek_back: "seek-", seek_forward: "seek+",
        remove_from_queue: "remove", remove_library_item: "remove",
        show_track_info: "info", show_help: "help", show_theme_picker: "theme",
      }.freeze

      def initialize(keymap:)
        @keymap = keymap
      end

      def render(screen, row:, w:, pane:, theme:, h: 1)
        pairs = @keymap.bindings_for(pane).filter_map do |key, action|
          next if action.to_s.start_with?("rate_")
          label = LABELS.fetch(action, action.to_s)
          label ? "#{key.upcase}:#{label}" : nil
        end
        # Greedy word-wrap of whole KEY:label pairs across h rows -- a pair
        # split mid-hint is unreadable. Overflow past the last row is dropped
        # (same behavior as the old single-line truncation).
        lines = [[]]
        pairs.each do |pair|
          candidate = (lines.last + [pair]).join("  ")
          if candidate.size <= w || lines.last.empty?
            lines.last << pair
          elsif lines.size < h
            lines << [pair]
          else
            break
          end
        end
        lines.each_with_index do |line, i|
          screen.put(row + i, 0, line.join("  ")[0, w], fg: theme[:text_muted])
        end
      end
    end
  end
end
