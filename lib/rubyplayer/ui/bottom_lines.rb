module RubyPlayer
  module UI
    class PlaybackLine
      def initialize(glyphs:)
        @glyphs = glyphs
      end

      def render(screen, row:, w:, state:, levels:, theme:)
        text, color = playback_text(state, theme)
        bars = eq_bars(levels)[0, w]
        # EQ remains anchored at right edge. Context yields first on narrow
        # terminals because clipped labels are less harmful than moving meters.
        text_width = [w - bars.size - (bars.empty? ? 0 : 1), 0].max
        screen.put(row, 0, text[0, text_width], fg: color, bold: true)
        screen.put(row, w - bars.size, bars, fg: theme[:success]) unless bars.empty?
      end

      private

      def playback_text(state, theme)
        next_text = state[:next_track] ? " · Next: #{state[:next_track].title}" : ""
        if state[:focus_sound]
          ["Focus — #{state[:focus_sound].title} ∞ Queue paused#{next_text}", theme[:primary]]
        elsif state[:track]
          track = state[:track]
          icon = state[:paused] ? @glyphs["pause"] : @glyphs["play"]
          time = "#{fmt(state[:position_ms])}/#{fmt(track.duration_ms)}"
          artist = track.artist ? " — #{track.artist}" : ""
          ["#{icon} #{track.title}#{artist}  #{time}#{next_text}", theme[:primary]]
        else
          ["#{@glyphs['pause']} stopped#{next_text}", theme[:text_muted]]
        end
      end

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

      # Exposed so App's dirty-flag renderer can detect the visual
      # transitions this line makes on its own (message appearing or timing
      # out) — the render loop no longer repaints unconditionally, so those
      # transitions would otherwise never hit the screen.
      def active?
        !!(@message && @clock.call < @expires_at)
      end

      # Seconds until the current message times out (nil when none is
      # showing) — lets the idle loop sleep exactly long enough instead of
      # polling for the expiry moment.
      def time_remaining
        active? ? @expires_at - @clock.call : nil
      end

      def render(screen, row:, w:, default:, theme:)
        text = active? ? @message : default
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
        sort_artist: "artist", sort_year: "year",
        next_track: "next", seek_back: "seek-", seek_forward: "seek+",
        remove_from_queue: "remove", remove_library_item: "remove",
        purge_visible_missing: "purge missing",
        show_track_info: "info", show_help: "help", show_theme_picker: "theme",
        filter_tracks: "filter", cycle_art_mode: "art",
        show_now_playing: "now playing",
        add_to_playlist: "playlist+", duplicate_playlist: "dup playlist",
        rename_playlist: "rename", move_entry_up: nil, move_entry_down: nil,
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
