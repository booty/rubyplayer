require "io/console"
require "tty-screen"
require_relative "../../rubyplayer"
require_relative "../audio_output"
require_relative "../playback_engine"

module RubyPlayer
  module UI
    class App
      RATE_ACTIONS = { rate_0: nil, rate_1: 1, rate_2: 2, rate_3: 3,
                       rate_4: 4, rate_5: 5, rate_6: 6 }.freeze

      attr_reader :engine, :library_pane, :tracks_pane, :active_pane, :input_buffer

      def initialize(argv: [], config_path: nil, data_path: nil, null_audio: false,
                     io_out: $stdout)
        @argv = argv
        @io_out = io_out
        @config = ConfigStore.new(path: config_path || RubyPlayer.config_path)
        @db = Database.new(path: data_path || File.join(RubyPlayer.data_dir, "library.sqlite3"),
                           backup_retention: @config["library", "backup_retention"])
        @library = Library.new(@db)
        @registry = Backends::Registry.new(@config["backends"])
        @bus = EventBus.new
        @audio = AudioOutput.new(sample_rate: @config["audio", "sample_rate"],
                                 ring_buffer_ms: @config["audio", "ring_buffer_ms"],
                                 null_backend: null_audio)
        @engine = PlaybackEngine.new(
          queue: PlayQueue.new(undo_depth: @config["library", "undo_depth"]),
          registry: @registry, audio: @audio, library: @library,
          event_bus: @bus, config: @config
        )
        @scanner = Scanner.new(library: @library, registry: @registry)
        @pool = ExtractorPool.new(library: @library, registry: @registry,
                                  thread_count: @config["scanner", "thread_count"],
                                  event_bus: @bus)
        @keymap = Keymap.new(@config["keymap"])
        glyphs = @config["glyphs"]
        @library_pane = LibraryPane.new(library: @library, glyphs: glyphs)
        @tracks_pane = TracksPane.new(library: @library, config: @config,
                                      queue_source: -> { @engine.queue_items })
        @playback_line = PlaybackLine.new(glyphs: glyphs)
        @status_line = StatusLine.new(seconds: @config["ui", "status_message_seconds"])
        @hotkey_line = HotkeyLine.new(keymap: @keymap)
        rows, cols = TTY::Screen.size
        @screen = Screen.new(out: io_out, rows: rows, cols: cols)
        @active_pane = :library
        @input_buffer = nil
        @quit = false
        @resized = false
        @engine.start
        @library_pane.rebuild!
        @tracks_pane.show(@library_pane.selected)
      end

      def quit? = @quit

      # Scans paths on a background thread; wait: true blocks (tests, startup
      # ordering). Progress arrives via the EventBus either way.
      def scan_paths(paths, wait: false)
        thread = Thread.new do
          paths.each { |p| @pool.process(@scanner.reconcile(p)) }
        end
        if wait
          thread.join
          refresh_panes
        end
        thread
      end

      def run
        setup_terminal
        trap("SIGWINCH") { @resized = true }
        scan_paths(@library.root_paths + @argv)
        frame_interval = 1.0 / @config["ui", "frame_fps"]
        until @quit
          ready = IO.select([$stdin, @bus.reader], nil, nil, frame_interval)
          read_input if ready&.first&.include?($stdin)
          handle_events
          handle_resize if @resized
          reload_config_if_changed
          render
        end
      ensure
        restore_terminal
        shutdown
      end

      def shutdown
        @engine.shutdown
        @audio.close
        @db.close
      end

      # ---- input ----

      def read_input
        bytes = $stdin.read_nonblock(1024)
        KeyDecoder.decode(bytes).each { |key| handle_key(key) }
      rescue IO::WaitReadable, EOFError
        nil
      end

      def handle_key(key)
        return handle_input_mode_key(key) if @input_buffer
        action = @keymap.action_for(key, pane: @active_pane)
        dispatch(action) if action
      end

      def handle_input_mode_key(key)
        case key
        when "enter"
          path = @input_buffer.strip
          @input_buffer = nil
          unless path.empty?
            @status_line.set_message("Scanning #{path}...")
            scan_paths([File.expand_path(path)])
          end
        when "escape" then @input_buffer = nil
        when "backspace" then @input_buffer = @input_buffer[0..-2]
        when "space" then @input_buffer += " "
        else @input_buffer += key if key.length == 1
        end
      end

      def dispatch(action)
        case action
        when :quit then @quit = true
        when :cycle_pane
          @active_pane = @active_pane == :library ? :tracks : :library
        when :toggle_play then @engine.toggle_play
        when :play_now then enqueue(:now)
        when :enqueue_front then enqueue(:front)
        when :enqueue_end then enqueue(:end)
        when :select_queue then select_queue
        when :undo
          @status_line.set_message("Queue restored (u:undo ctrl_r:redo)") if @engine.undo
          select_queue
        when :redo
          @engine.redo
          select_queue
        when :toggle_skip_disliked
          on = @engine.toggle_skip_disliked
          @status_line.set_message("Skip disliked tracks: #{on ? 'ON' : 'OFF'}")
        when :add_path then @input_buffer = ""
        when :next_track
          @engine.skip
          @status_line.set_message("Skipped")
        when :seek_forward then seek_by(1)
        when :seek_back then seek_by(-1)
        when :remove_from_queue then remove_from_queue
        when *RATE_ACTIONS.keys then rate_current(RATE_ACTIONS[action])
        else route_to_pane(action)
        end
      end

      # engine.seek takes an ABSOLUTE ms position (see PlaybackEngine#seek),
      # so both directions are computed relative to the current position
      # rather than as a delta the engine could apply itself; back is
      # clamped at 0 so repeated presses near the start don't go negative.
      def seek_by(direction)
        return unless @engine.state[:track]
        seek_ms = @config["ui", "seek_seconds"] * 1000
        target = @engine.state[:position_ms] + (direction * seek_ms)
        @engine.seek([target, 0].max)
      end

      # Removing from the queue is gated to the Playback Queue view (rather
      # than, say, letting "x" also act on a folder's track list) because
      # the tracks pane doesn't distinguish "queue position" from "row in
      # whatever's currently shown" -- selected_track_index only means
      # "queue index" when that's actually what's on screen.
      def remove_from_queue
        if @library_pane.selected&.kind != :queue
          @status_line.set_message("Select a track in the Playback Queue to remove")
          return
        end
        index = @tracks_pane.selected_track_index
        if index.nil?
          @status_line.set_message("Select a track in the Playback Queue to remove")
          return
        end
        @engine.remove_at(index)
        @status_line.set_message("Removed from queue (u:undo)")
      end

      def route_to_pane(action)
        if @active_pane == :library
          before = @library_pane.selected
          @library_pane.handle_action(action)
          @tracks_pane.show(@library_pane.selected) if @library_pane.selected != before
        else
          @tracks_pane.handle_action(action)
        end
      end

      def enqueue(where)
        tracks = selected_tracks
        return if tracks.empty?
        case where
        when :now then @engine.enqueue_now(tracks)
        when :front then @engine.enqueue_front(tracks)
        when :end then @engine.enqueue_end(tracks)
        end
        @status_line.set_message("#{tracks.size} track#{'s' if tracks.size != 1} enqueued (u:undo)")
      end

      def selected_tracks
        if @active_pane == :tracks
          # Track is a Struct, and Kernel#Array(struct) would splat it into its
          # field VALUES ([id, folder_id, ...]) rather than wrap it — which would
          # enqueue an Integer id as a "track". Wrap-and-compact keeps the Track
          # (and yields [] when nothing is selected).
          [@tracks_pane.selected_track].compact
        else
          row = @library_pane.selected
          case row&.kind
          when :folder then @library.tracks_under(row.folder["id"])
          when :favorites then @library.favorites
          else []
          end
        end
      end

      def rate_current(rating)
        track = @engine.state[:track]
        return unless track
        @library.set_rating(track.id, rating)
        @status_line.set_message(rating ? "Rated #{rating}/6" : "Rating cleared")
        @tracks_pane.reload!
      end

      def select_queue
        @library_pane.handle_action(:select_queue)
        @tracks_pane.show(@library_pane.selected)
        @active_pane = :library
      end

      # ---- events / config ----

      def handle_events
        refresh = false
        @bus.drain.each do |type, payload|
          case type
          when :queue_changed, :track_started, :track_ended then refresh = true
          when :scan_complete
            @status_line.set_message(
              "Scan complete: #{payload[:processed]} files, #{payload[:errored]} errors"
            )
            refresh = true
          when :track_error
            @status_line.set_message("Error playing #{payload[:track]&.title}: skipped")
          end
        end
        refresh_panes if refresh
      end

      def refresh_panes
        @library_pane.rebuild!
        # Playback/scan events change pane *contents*, not which view is shown,
        # so reload! (preserves @mode/@selection/@scroll, just re-clamps) is
        # correct here. `show` is reserved for actual selection changes (see
        # route_to_pane/select_queue) where resetting the cursor is desired.
        @tracks_pane.reload!
      end

      def reload_config_if_changed
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_config_check ||= now
        return if now - @last_config_check < 1.0
        @last_config_check = now
        return unless @config.reload_if_changed
        @keymap = Keymap.new(@config["keymap"])
        @hotkey_line = HotkeyLine.new(keymap: @keymap)
        @tracks_pane.update_config(@config)
        @status_line.set_message("Config reloaded")
      end

      # ---- rendering ----

      def render
        @screen.clear_back
        rows = @screen.rows
        cols = @screen.cols
        content_h = rows - 3
        lib_w = cols * @config["ui", "library_pane_percent"] / 100
        draw_box(0, 0, lib_w, content_h, active: @active_pane == :library, title: "Library")
        draw_box(lib_w, 0, cols - lib_w, content_h, active: @active_pane == :tracks, title: "Tracks")
        @library_pane.render(@screen, x: 1, y: 1, w: lib_w - 2, h: content_h - 2,
                             active: @active_pane == :library)
        @tracks_pane.render(@screen, x: lib_w + 1, y: 1, w: cols - lib_w - 2,
                            h: content_h - 2, active: @active_pane == :tracks)
        @playback_line.render(@screen, row: rows - 3, w: cols,
                              state: @engine.state, levels: @engine.levels)
        if @input_buffer
          @screen.put(rows - 2, 0, "Add path: #{@input_buffer}_"[0, cols], fg: :bright_yellow)
        else
          stats = @library.folder_stats
          @status_line.render(@screen, row: rows - 2, w: cols,
                              default: "#{stats[:tracks]} tracks in #{stats[:folders]} folders")
        end
        @hotkey_line.render(@screen, row: rows - 1, w: cols, pane: @active_pane)
        @screen.flush
      end

      def draw_box(x, y, w, h, active:, title:)
        color = active ? :bright_cyan : :bright_black
        @screen.put(y, x, "┌#{"─" * (w - 2)}┐", fg: color)
        (1...(h - 1)).each do |i|
          @screen.put(y + i, x, "│", fg: color)
          @screen.put(y + i, x + w - 1, "│", fg: color)
        end
        @screen.put(y + h - 1, x, "└#{"─" * (w - 2)}┘", fg: color)
        @screen.put(y, x + 2, " #{title} ", fg: color, bold: active)
      end

      # ---- terminal ----

      def setup_terminal
        $stdin.raw! if $stdin.tty?
        @io_out.write("\e[?1049h\e[?25l\e[?2004h") # alt screen, hide cursor, bracketed paste
      end

      def restore_terminal
        @io_out.write("\e[?2004l\e[?25h\e[?1049l")
        $stdin.cooked! if $stdin.tty?
      end

      def handle_resize
        @resized = false
        rows, cols = TTY::Screen.size
        @screen.resize(rows, cols)
      end
    end
  end
end
