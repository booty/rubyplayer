# frozen_string_literal: true

require_relative '../duration_formatter'

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
        next_text = state[:next_track] ? " · Next: #{state[:next_track].title}" : ''
        if state[:focus_sound]
          ["Focus — #{state[:focus_sound].title} ∞ Queue paused#{next_text}", theme[:primary]]
        elsif state[:track]
          track = state[:track]
          icon = state[:paused] ? @glyphs['pause'] : @glyphs['play']
          time = "#{fmt(state[:position_ms])}/#{fmt(track.duration_ms)}"
          artist = track.artist ? " — #{track.artist}" : ''
          ["#{icon} #{track.title}#{artist}  #{time}#{next_text}", theme[:primary]]
        else
          ["#{@glyphs['pause']} stopped#{next_text}", theme[:text_muted]]
        end
      end

      def eq_bars(levels)
        chars = @glyphs['eq_chars']
        levels.map { |l| chars[(l * (chars.size - 1)).round] }.join
      end

      def fmt(ms)
        DurationFormatter.format(ms, unknown: '?:??')
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
        cycle_pane: 'panes', toggle_play: 'play/pause', play_now: 'play now',
        enqueue_front: 'queue next', enqueue_end: 'queue last', select_queue: 'queue',
        undo: 'undo', redo: 'redo', toggle_skip_disliked: 'skip 1-star', add_path: 'add',
        quit: 'quit', nav_up: nil, nav_down: nil, collapse: nil, expand: nil,
        nav_page_up: nil, nav_page_down: nil,
        toggle_group: 'group', sort_title: 'title', sort_number: 'number',
        sort_artist: 'artist', sort_year: 'year',
        next_track: 'next', previous_track: 'restart/prev', seek_back: 'seek-', seek_forward: 'seek+',
        remove_from_queue: 'remove', remove_library_item: 'remove',
        purge_visible_missing: 'purge missing',
        show_track_info: 'info', show_help: 'help', show_theme_picker: 'theme',
        filter_tracks: 'filter', cycle_art_mode: 'art', toggle_queued_pane: 'queue bar',
        show_now_playing: 'now playing',
        add_to_playlist: 'playlist+', duplicate_playlist: 'dup playlist',
        rename_playlist: 'rename', move_entry_up: nil, move_entry_down: nil
      }.freeze

      ROWS = 3
      COMPACT_WIDTH = 100
      PLAY_GROUPS = [%i[toggle_play previous_track next_track seek_back seek_forward],
                     %i[toggle_skip_disliked show_now_playing]].freeze
      QUEUE_GROUPS = [%i[play_now enqueue_front enqueue_end select_queue],
                      %i[remove_from_queue undo redo add_to_playlist]].freeze
      VIEW_GROUPS = [%i[cycle_pane filter_tracks toggle_group],
                     %i[sort_title sort_number sort_artist sort_year show_track_info]].freeze
      COMPACT_VIEW_GROUPS = [%i[cycle_pane filter_tracks toggle_group show_track_info]].freeze
      LIBRARY_GROUPS = [%i[cycle_pane filter_tracks], %i[add_path remove_library_item],
                        %i[duplicate_playlist rename_playlist]].freeze
      # The Now Playing pane has no list: 0-6 rate the playing track there.
      NOW_PLAYING_GROUPS = [%i[cycle_pane cycle_art_mode]].freeze
      CONTEXT_TITLES = { library: 'LIBRARY', now_playing: 'NOW PLAYING' }.freeze
      FOOTER_LABELS = { toggle_play: 'pause', seek_back: 'back', seek_forward: 'forward',
                        toggle_skip_disliked: 'skip disliked' }.freeze
      COMPACT_LABELS = { previous_track: 'prev/start', seek_forward: 'fwd',
                         enqueue_front: 'next', enqueue_end: 'last', toggle_skip_disliked: 'skip1',
                         show_now_playing: 'now', duplicate_playlist: 'duplicate' }.freeze
      STYLES = { category: { italic: true }, key: { bold: true }, muted: { dim: true } }.freeze
      TOGGLE_ACTIONS = %i[toggle_skip_disliked toggle_group].freeze
      private_constant :COMPACT_WIDTH, :PLAY_GROUPS, :QUEUE_GROUPS, :VIEW_GROUPS,
                       :COMPACT_VIEW_GROUPS, :LIBRARY_GROUPS, :NOW_PLAYING_GROUPS, :CONTEXT_TITLES,
                       :FOOTER_LABELS, :COMPACT_LABELS, :STYLES, :TOGGLE_ACTIONS

      def self.key_label(key)
        key.to_s.upcase.sub(/\ACTRL[_+]/, '^').sub(/\ASPACE\z/, 'Space')
           .sub(/\AENTER\z/, 'Enter').sub(/\ATAB\z/, 'Tab')
      end

      def initialize(keymap:)
        @bindings = %i[library tracks queued now_playing].to_h do |pane|
          [pane, keymap.bindings_for(pane).group_by(&:last)]
        end
      end

      def render(screen, row:, w:, pane:, theme:, h: ROWS, toggle_states: {})
        bindings = @bindings.fetch(pane.to_sym)
        context = CONTEXT_TITLES.fetch(pane.to_sym, 'VIEW')
        groups = context_groups(pane, w)
        help_key = bindings[:show_help]&.last&.first
        labels = hint_labels(toggle_states, compact: w < COMPACT_WIDTH)
        rows = [['PLAY', PLAY_GROUPS], ['QUEUE', QUEUE_GROUPS], [context, groups]]
        rows.first(h).each_with_index do |(title, actions), index|
          help = index == ROWS - 1 ? help_key : nil
          row_fragments(title, actions, bindings, w, help: help, labels: labels).each do |col, text, style|
            color = style == :key ? theme[:text] : theme[:text_muted]
            screen.put(row + index, col, text, fg: color, **STYLES.fetch(style))
          end
        end
      end

      private

      def context_groups(pane, width)
        return LIBRARY_GROUPS if pane.to_sym == :library
        return NOW_PLAYING_GROUPS if pane.to_sym == :now_playing

        width < COMPACT_WIDTH ? COMPACT_VIEW_GROUPS : VIEW_GROUPS
      end

      def row_fragments(title, groups, bindings, width, help:, labels:)
        help_label = "#{self.class.key_label(help)}:" if help
        help_text = LABELS.fetch(:show_help)
        help_width = help_label ? help_label.size + help_text.size : 0
        help_width = 0 if help_width > width
        limit = help_width.positive? ? width - help_width - 2 : width
        fragments = [[0, title[0, [limit, 0].max], :category]]
        x = title.size + 3
        groups.each do |group|
          hints = group.flat_map { |action| bindings.fetch(action, []) }
          x = append_group(fragments, hints, x: x, limit: limit, labels: labels)
        end
        if help_width.positive?
          fragments << [width - help_width, help_label, :key]
          fragments << [width - help_text.size, help_text, :muted]
        end
        fragments
      end

      # Reserve help before fitting hints. Omit whole hints rather than clipping
      # key labels or letting commands spill into another category's row.
      def append_group(fragments, hints, x:, limit:, labels:)
        started = false
        hints.each do |key, action|
          label = labels.fetch(action)
          key_label = "#{self.class.key_label(key)}:"
          prefix = if started
                     '  '
                   elsif fragments.any? { |fragment| fragment.last == :key }
                     ' │ '
                   else
                     ''
                   end
          next if x + prefix.size + key_label.size + label.size > limit

          fragments << [x, prefix, :muted] unless prefix.empty?
          x += prefix.size
          fragments << [x, key_label, :key]
          fragments << [x + key_label.size, label, :muted]
          x += key_label.size + label.size
          started = true
        end
        x
      end

      def hint_labels(toggle_states, compact:)
        labels = LABELS.merge(FOOTER_LABELS)
        labels.merge!(COMPACT_LABELS) if compact
        TOGGLE_ACTIONS.each do |action|
          labels[action] = "#{labels.fetch(action)} (#{toggle_states[action] ? 'on' : 'off'})"
        end
        labels
      end
    end
  end
end
