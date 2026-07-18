require "io/console"
require "shellwords"
require "tty-screen"
require_relative "../../rubyplayer"
require_relative "../audio_output"
require_relative "../playback_engine"

module RubyPlayer
  module UI
    class App
      SINGLE_PANE_MAX_WIDTH = 71
      RATE_ACTIONS = { rate_0: nil, rate_1: 1, rate_2: 2, rate_3: 3,
                       rate_4: 4, rate_5: 5, rate_6: 6 }.freeze

      attr_reader :engine, :library_pane, :tracks_pane, :active_pane, :input_buffer,
                  :pending_delete, :info_track, :show_help, :theme_id, :theme_picker,
                  :focus_player, :filter_buffer, :pending_missing_purge, :config_error

      def initialize(argv: [], config_path: nil, data_path: nil, null_audio: false,
                     io_out: $stdout, focus_player: nil)
        @argv = argv
        @io_out = io_out
        @config = ConfigStore.new(path: config_path || RubyPlayer.config_path)
        @config_error = @config.startup_error
        @db = Database.new(path: data_path || File.join(RubyPlayer.data_dir, "library.sqlite3"),
                           backup_retention: @config["library", "backup_retention"])
        @library = Library.new(@db)
        @registry = Backends::Registry.new(@config["backends"])
        @bus = EventBus.new
        @audio = AudioOutput.new(sample_rate: @config["audio", "sample_rate"],
                                 ring_buffer_ms: @config["audio", "ring_buffer_ms"],
                                 null_backend: null_audio)
        @archive_cache = ArchiveCache.new(root: @config["library", "archive_cache_dir"],
                                          tar: @config["library", "archive_tool"])
        @focus_player = focus_player || FocusPlayer.new
        @engine = PlaybackEngine.new(
          queue: PlayQueue.new(undo_depth: @config["library", "undo_depth"]),
          registry: @registry, audio: @audio, library: @library,
          event_bus: @bus, config: @config, archive_cache: @archive_cache,
          focus_player: @focus_player
        )
        @scanner = Scanner.new(library: @library, registry: @registry)
        @pool = ExtractorPool.new(library: @library, registry: @registry,
                                  thread_count: @config["scanner", "thread_count"],
                                  event_bus: @bus, archive_cache: @archive_cache)
        @keymap = Keymap.new(@config["keymap"])
        glyphs = @config["glyphs"]
        @library_pane = LibraryPane.new(library: @library, glyphs: glyphs)
        @tracks_pane = TracksPane.new(library: @library, config: @config,
                                      queue_source: -> { @engine.queue_items },
                                      focus_source: -> { FocusSounds::ALL })
        @playback_line = PlaybackLine.new(glyphs: glyphs)
        @status_line = StatusLine.new(seconds: @config["ui", "status_message_seconds"])
        @hotkey_line = HotkeyLine.new(keymap: @keymap)
        rows, cols = TTY::Screen.size
        @screen = Screen.new(out: io_out, rows: rows, cols: cols)
        @active_pane = :library
        @input_buffer = nil
        @filter_buffer = nil
        @filter_before_edit = nil
        @pending_delete = nil
        @pending_missing_purge = nil
        @info_track = nil
        @show_help = false
        @theme_picker = false
        @theme_picker_index = 0
        @theme_id_before_preview = nil
        set_theme!(@config["ui", "theme"])
        @quit = false
        @resized = false
        # Dirty-flag rendering: the loop paints only when something visual
        # changed. Start dirty so the first pass paints the initial frame.
        @needs_render = true
        @message_was_active = false
        @frame_interval = 1.0 / @config["ui", "frame_fps"]
        @idle_poll = @config["ui", "idle_poll_seconds"]
        @engine.start
        @library_pane.rebuild!
        show_selected_tracks
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
        until @quit
          ready = IO.select([$stdin, @bus.reader], nil, nil, select_timeout)
          read_input if ready&.first&.include?($stdin)
          handle_events
          handle_resize if @resized
          reload_config_if_changed
          render_if_needed
        end
      ensure
        restore_terminal
        shutdown
      end

    def shutdown
      first_error = nil
      # Shutdown is best-effort across independent resources. Focus process
      # failure must not leave decoder thread, native audio, or SQLite open;
      # preserve the first error so callers still learn cleanup was incomplete.
      [-> { @engine.shutdown }, -> { @audio.close }, -> { @db.close }].each do |cleanup|
        cleanup.call
      rescue StandardError => e
        first_error ||= e
      end
      raise first_error if first_error
    end

      # ---- input ----

      def read_input
        bytes = $stdin.read_nonblock(1024)
        KeyDecoder.decode(bytes).each { |key| handle_key(key) }
      rescue IO::WaitReadable, EOFError
        nil
      end

      def handle_key(key)
        # Over-approximation: an unbound key dirties the frame too. One
        # wasted repaint per stray keypress is cheaper than auditing every
        # dispatch path for whether it changed something visible.
        @needs_render = true
        return handle_config_error_key(key) if @config_error
        return handle_theme_picker_key(key) if @theme_picker
        return handle_help_key(key) if @show_help
        return handle_info_key(key) if @info_track
        return handle_missing_purge_key(key) if @pending_missing_purge
        return handle_confirm_key(key) if @pending_delete
        return handle_paste(key.text) if key.is_a?(KeyDecoder::Paste)
        return handle_filter_mode_key(key) if @filter_buffer
        return handle_input_mode_key(key) if @input_buffer
        action = @keymap.action_for(key, pane: @active_pane)
        dispatch(action) if action
      end

      # Up/Down cycle through Theme::ALL_IDS and immediately re-theme the
      # whole app (live preview) without touching config; Enter persists
      # whatever's currently previewed, Escape/t reverts to whatever was
      # active before the picker was opened.
      def handle_theme_picker_key(key)
        case key
        when "up" then move_theme_preview(-1)
        when "down" then move_theme_preview(1)
        when "enter"
          begin
            @config.persist_theme(@theme_id)
            @theme_picker = false
          rescue ConfigError => error
            set_theme!(@config["ui", "theme"])
            @theme_picker = false
            @config_error = error
          end
        when "escape", "t"
          set_theme!(@theme_id_before_preview)
          @theme_picker = false
        end
      end

      def handle_config_error_key(key)
        @config_error = nil if %w[escape enter].include?(key)
      end

      def move_theme_preview(delta)
        ids = Theme::ALL_IDS
        @theme_picker_index = (@theme_picker_index + delta) % ids.size
        set_theme!(ids[@theme_picker_index])
      end

      def handle_help_key(key)
        @show_help = false if %w[? escape enter].include?(key)
      end

      # Any of these three dismiss the info modal; everything else is
      # swallowed rather than falling through to normal dispatch, same as
      # the confirm-delete and add-path input-capture states below.
      def handle_info_key(key)
        @info_track = nil if %w[i escape enter].include?(key)
      end

      # While a delete confirmation modal is up, keys are captured here
      # instead of reaching the keymap -- mirrors how @input_buffer steals
      # input for the add-path prompt (see handle_input_mode_key).
      def handle_confirm_key(key)
        case key
        when "y", "enter" then confirm_delete
        when "n", "escape" then @pending_delete = nil
        end
      end

      def handle_missing_purge_key(key)
        case key
        when "y", "enter" then confirm_missing_purge
        when "n", "escape" then @pending_missing_purge = nil
        end
      end

      # Shared line-editing for the two text-capture states (add-path prompt
      # and filter). Returns the edited string, or nil for keys that aren't
      # edits — enter/escape semantics differ per state and stay in each
      # handler. KeyDecoder names special keys with multi-char strings
      # ("up", "f5"), so the length check is what keeps them out of the text.
      def edit_line(buffer, key)
        case key
        when "backspace" then buffer[0..-2]
        when "space" then buffer + " "
        else key.length == 1 ? buffer + key : nil
        end
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
        else
          edited = edit_line(@input_buffer, key)
          @input_buffer = edited if edited
        end
      end

      def handle_paste(text)
        if @filter_buffer
          @filter_buffer += text
          @tracks_pane.filter = @filter_buffer
          return
        end

        paths = Shellwords.shellsplit(text).map { |path| File.expand_path(path) }
        return if paths.empty?

        @status_line.set_message("Scanning #{paths.join(', ')}...")
        scan_paths(paths)
      rescue ArgumentError
        @status_line.set_message("Could not read dropped path")
      end

      def handle_filter_mode_key(key)
        case key
        when "enter"
          @filter_buffer = nil
          @filter_before_edit = nil
        when "escape"
          @tracks_pane.filter = @filter_before_edit
          @filter_buffer = nil
          @filter_before_edit = nil
        else
          edited = edit_line(@filter_buffer, key)
          if edited
            @filter_buffer = edited
            @tracks_pane.filter = edited
          end
        end
      end

      def dispatch(action)
        case action
        when :quit then @quit = true
        when :cycle_pane
          @active_pane = @active_pane == :library ? :tracks : :library
        when :toggle_play
          @engine.toggle_play
        when :play_now then play_now
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
        when :filter_tracks
          @active_pane = :tracks
          @filter_before_edit = @tracks_pane.filter
          @filter_buffer = @tracks_pane.filter.dup
        when :next_track
          @engine.skip
          @status_line.set_message("Skipped")
        when :seek_forward then seek_by(1)
        when :seek_back then seek_by(-1)
        when :remove_from_queue then remove_from_queue
        when :remove_library_item then request_remove_library_item
        when :purge_visible_missing then request_missing_purge
        when :show_track_info then request_show_track_info
        when :show_help then @show_help = true
        when :show_theme_picker then request_show_theme_picker
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
        selected = @tracks_pane.selected_queue_track
        # Filtering changes display positions. Resolve selected object against
        # live queue identity so removing visible row cannot delete hidden row.
        index = @engine.queue_items.index { |track| track.equal?(selected) }
        if index.nil?
          @status_line.set_message("Select a track in the Playback Queue to remove")
          return
        end
        @engine.remove_at(index)
        @status_line.set_message("Removed from queue (u:undo)")
      end

      # Only :folder rows are removable -- fixed smart/source rows are computed views, not library
      # entries, so there's nothing in the DB for them to remove.
      def request_remove_library_item
        row = @library_pane.selected
        if row&.kind != :folder
          @status_line.set_message("Only library folders can be removed")
          return
        end
        @pending_delete = row.folder
      end

      def request_missing_purge
        unless @library_pane.selected&.kind == :missing
          @status_line.set_message("Select Missing view to purge tracks")
          return
        end

        ids = @tracks_pane.visible_tracks.map(&:id)
        if ids.empty?
          @status_line.set_message("No visible missing tracks to purge")
          return
        end

        # Capture IDs now: confirmation must describe and delete same filtered
        # set even if background events reload pane before user answers.
        @pending_missing_purge = { ids: ids.freeze, count: ids.size }.freeze
      end

      def confirm_missing_purge
        pending = @pending_missing_purge
        @pending_missing_purge = nil
        deleted = @library.purge_missing_tracks!(pending[:ids])
        @engine.remove_track_ids(deleted) unless deleted.empty?
        @folder_stats = nil
        @library_pane.rebuild!
        show_selected_tracks
        @status_line.set_message(
          "Permanently removed #{deleted.size} missing track#{'s' unless deleted.size == 1}"
        )
      end

      def confirm_delete
        folder = @pending_delete
        @pending_delete = nil
        track_ids = @library.remove_folder!(folder["id"])
        @engine.remove_track_ids(track_ids) unless track_ids.empty?
        @folder_stats = nil
        @library_pane.rebuild!
        show_selected_tracks
        @status_line.set_message("Removed \"#{folder['name']}\" from library")
      end

      # Bound only in the "tracks" keymap scope (see keymap.rb), so this is
      # never reached while the Library pane is active.
      def request_show_track_info
        track = @tracks_pane.selected_track
        unless track
          @status_line.set_message("Select a track to view info")
          return
        end
        @info_track = track
      end

      def request_show_theme_picker
        @theme_id_before_preview = @theme_id
        @theme_picker_index = Theme::ALL_IDS.index(@theme_id) || 0
        @theme_picker = true
      end

      def set_theme!(id)
        id = id.to_s.to_sym
        id = :default unless Theme::ALL_IDS.include?(id)
        @theme_id = id
        @theme = Theme[id]
      end

      def route_to_pane(action)
        if @active_pane == :library
          before = @library_pane.selected
          @library_pane.handle_action(action)
          show_selected_tracks if @library_pane.selected != before
        else
          outcome = @tracks_pane.handle_action(action)
          # Panes describe unavailable actions but do not own StatusLine;
          # App remains sole coordinator for transient user-facing feedback.
          @status_line.set_message(outcome[1]) if outcome.is_a?(Array) && outcome[0] == :disabled
        end
      end

      def enqueue(where)
        # Focus sounds are infinite generators, not finite Tracks. Letting one
        # into PlayQueue would break duration, advance, history, and persistence
        # assumptions throughout PlaybackEngine.
        if selected_focus_sound
          @status_line.set_message("Focus sounds cannot be queued")
          return
        end
        tracks = selected_tracks
        return if tracks.empty?
        @engine.stop_focus
        case where
        when :now then @engine.enqueue_now(tracks)
        when :front then @engine.enqueue_front(tracks)
        when :end then @engine.enqueue_end(tracks)
        end
        @status_line.set_message("#{tracks.size} track#{'s' if tracks.size != 1} enqueued (u:undo)")
      end

      def play_now
        sound = selected_focus_sound
        return play_focus(sound) if sound

        enqueue(:now)
      end

      def play_focus(sound)
        # Decoder thread owns both normal-track and Focus writes. This command
        # performs source handoff there, preserving queue while preventing any
        # second Ruby thread from entering AudioOutput's native ring writer.
        @engine.play_focus(sound)
        @status_line.set_message("Playing focus: #{sound.title}")
      rescue FocusPlayer::Error => e
        @status_line.set_message(e.message)
      end

      def selected_focus_sound
        @active_pane == :tracks && @tracks_pane.selected_focus_sound
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
          if row&.kind == :folder
            @library.tracks_under(row.folder["id"])
          else
            # Views.query returns [] for queue/history/focus (nil query in the
            # table), preserving the rule that enqueueing those sidebar rows
            # wholesale is a no-op.
            Views.query(row&.kind, @library)
          end
        end
      end

      def rate_current(rating)
        track = @engine.state[:track]
        unless track
          @status_line.set_message("Play a library track before rating")
          return
        end
        @library.set_rating(track.id, rating)
        @status_line.set_message(rating ? "Rated #{rating}/6" : "Rating cleared")
        @tracks_pane.reload!
      end

      def select_queue
        @library_pane.handle_action(:select_queue)
        show_selected_tracks
        @active_pane = :library
      end

      # ---- events / config ----

      def handle_events
        refresh = false
        events = @bus.drain
        # Any event may carry a visible change (position tick, scan progress,
        # queue mutation) — cheaper to repaint once than to classify.
        @needs_render = true unless events.empty?
        events.each do |type, payload|
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
        @folder_stats = nil
        # Callers outside the key/event paths (scan_paths wait: true) reach
        # here too — pane contents changed, so the next frame must paint.
        @needs_render = true
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
        begin
          return unless @config.reload_if_changed
        rescue ConfigError => error
          @config_error = error
          @needs_render = true # the error modal must appear without a keypress
          return
        end
        @config_error = nil
        @needs_render = true
        @keymap = Keymap.new(@config["keymap"])
        @hotkey_line = HotkeyLine.new(keymap: @keymap)
        @frame_interval = 1.0 / @config["ui", "frame_fps"]
        @idle_poll = @config["ui", "idle_poll_seconds"]
        @tracks_pane.update_config(@config)
        # Don't clobber an in-progress interactive preview with whatever's
        # still on disk -- the picker itself is the source of truth for
        # @theme_id until it's closed.
        set_theme!(@config["ui", "theme"]) unless @theme_picker
        @status_line.set_message("Config reloaded")
      end

      # ---- rendering ----

      # Painting is skipped unless something visual could have changed: a
      # dirty flag set by input/events/resize/config paths, an active
      # playback or focus source (position counter and level meters move
      # every frame), or the status message flipping between shown and
      # expired — that last transition happens purely by clock, so it's
      # detected here rather than at a set_message call site. Idle, this
      # turns 30 full frame builds per second into zero.
      def render_if_needed
        message_active = @status_line.active?
        return unless @needs_render || animating? || message_active != @message_was_active

        render
        @needs_render = false
        @message_was_active = message_active
      end

      def animating?
        state = @engine.state
        !!(state[:focus_sound] || (state[:playing] && !state[:paused]))
      end

      # How long IO.select may block. While animating, the frame interval
      # caps the position/EQ refresh rate. Idle, stdin and the EventBus
      # self-pipe wake select on their own, so the timeout only bounds two
      # things select can't see: the SIGWINCH resize flag (idle_poll) and
      # the status message's clock-driven expiry (time_remaining). This cuts
      # idle wake-ups from 30/s to 4/s.
      def select_timeout
        return @frame_interval if animating?

        [@idle_poll, @status_line.time_remaining].compact.min
      end

      def render
        @screen.clear_back
        rows = @screen.rows
        cols = @screen.cols
        content_h = rows - 4 # playback + status + 2-row hotkey hint
        render_panes(cols, content_h)
        @playback_line.render(@screen, row: rows - 4, w: cols,
                              state: @engine.state, levels: @engine.levels, theme: @theme)
        if @filter_buffer
          @screen.put(rows - 3, 0, "Filter: #{@filter_buffer}_"[0, cols], fg: @theme[:accent])
        elsif @input_buffer
          @screen.put(rows - 3, 0, "Add path: #{@input_buffer}_"[0, cols], fg: @theme[:accent])
        else
          # Cached because render runs at 30fps and the counts only change
          # when the library does — without this, the idle status line costs
          # two SQLite COUNT(*) queries per frame. Invalidated wherever panes
          # rebuild after a library change (refresh_panes, delete/purge).
          @folder_stats ||= @library.folder_stats
          @status_line.render(@screen, row: rows - 3, w: cols,
                              default: "#{@folder_stats[:tracks]} tracks in #{@folder_stats[:folders]} folders",
                              theme: @theme)
        end
        @hotkey_line.render(@screen, row: rows - 2, w: cols, h: 2, pane: @active_pane, theme: @theme)
        render_confirm_modal if @pending_delete
        render_missing_purge_modal if @pending_missing_purge
        render_info_modal if @info_track
        render_help_modal if @show_help
        render_theme_picker_modal if @theme_picker
        render_config_error_modal if @config_error
        @screen.flush
      end

      def render_panes(cols, content_h)
        # Below 72 columns, two bordered panes leave too little usable text.
        # Keep full-width active pane and let existing Tab binding switch it.
        if cols <= SINGLE_PANE_MAX_WIDTH
          if @active_pane == :library
            draw_box(0, 0, cols, content_h, active: true, title: "Library")
            @library_pane.render(@screen, x: 1, y: 1, w: cols - 2, h: content_h - 2,
                                 active: true, theme: @theme)
          else
            title = @tracks_pane.title(max_width: cols - 6)
            draw_box(0, 0, cols, content_h, active: true, title: title)
            @tracks_pane.render(@screen, x: 1, y: 1, w: cols - 2, h: content_h - 2,
                                active: true, theme: @theme)
          end
          return
        end

        lib_w = cols * @config["ui", "library_pane_percent"] / 100
        tracks_w = cols - lib_w
        draw_box(0, 0, lib_w, content_h, active: @active_pane == :library, title: "Library")
        draw_box(lib_w, 0, tracks_w, content_h, active: @active_pane == :tracks,
                 title: @tracks_pane.title(max_width: tracks_w - 6))
        @library_pane.render(@screen, x: 1, y: 1, w: lib_w - 2, h: content_h - 2,
                             active: @active_pane == :library, theme: @theme)
        @tracks_pane.render(@screen, x: lib_w + 1, y: 1, w: tracks_w - 2,
                            h: content_h - 2, active: @active_pane == :tracks, theme: @theme)
      end

      def show_selected_tracks
        row = @library_pane.selected
        @tracks_pane.show(row, breadcrumb: @library_pane.breadcrumb_for(row))
      end

      # Screen has no z-order/layers (see Screen#put) -- modals paint over the
      # panes only because App#render draws them last. This helper owns the
      # chrome every modal must repeat correctly: centering (clamped so tiny
      # terminals don't get negative coordinates) and the full surface fill.
      # Skipping the fill is the historical bug class here -- pane text would
      # bleed through any gap between the modal's own put calls. Yields the
      # top-left corner; the optional hint is the standard muted close/confirm
      # line every modal places on its bottom inner row.
      def render_modal(title:, w:, h:, hint: nil, hint_bg: nil)
        x = [(@screen.cols - w) / 2, 0].max
        y = [(@screen.rows - h) / 2, 0].max
        (1...(h - 1)).each { |i| @screen.put(y + i, x + 1, " " * (w - 2), bg: @theme[:surface]) }
        draw_box(x, y, w, h, active: true, title: title)
        yield x, y if block_given?
        @screen.put(y + h - 2, x + 2, hint[0, w - 4], fg: @theme[:text_muted], bg: hint_bg) if hint
      end

      def render_confirm_modal
        folder = @pending_delete
        message = "Remove \"#{folder['name']}\" from library?"
        hint = "Also removes its tracks from Favorites and the Playback Queue."
        prompt = "[y] Yes    [n/esc] Cancel"
        w = [message.size, hint.size, prompt.size].max + 4
        render_modal(title: "Confirm Remove", w: w, h: 6) do |x, y|
          @screen.put(y + 2, x + 2, message[0, w - 4], fg: @theme[:accent], bold: true)
          @screen.put(y + 3, x + 2, hint[0, w - 4], fg: @theme[:text_muted])
          @screen.put(y + 4, x + 2, prompt[0, w - 4], fg: @theme[:primary], bold: true)
        end
      end

      def render_missing_purge_modal
        count = @pending_missing_purge[:count]
        pronoun = count == 1 ? "its" : "their"
        message = "Permanently remove #{count} missing track#{'s' unless count == 1} and #{pronoun} history?"
        prompt = "[y] Remove    [n/esc] Cancel"
        w = [message.size, prompt.size].max + 4
        render_modal(title: "Confirm Purge", w: w, h: 5) do |x, y|
          @screen.put(y + 2, x + 2, message[0, w - 4], fg: @theme[:accent], bold: true)
          @screen.put(y + 3, x + 2, prompt[0, w - 4], fg: @theme[:primary], bold: true)
        end
      end

      # Rows are built as [label, value] pairs and only included when they
      # apply (archive/subtune fields for plain files, missing/errored flags
      # for healthy tracks) so a typical track's modal isn't cluttered with
      # blank fields.
      def render_info_modal
        t = @info_track
        stats = @library.play_stats(t.id)
        rows = [
          ["Title", t.title], ["Album", t.album], ["Artist", t.artist],
          ["Composer", t.composer], ["Track #", t.track_number],
          ["Format", t.format], ["Backend", t.backend],
          ["Length", fmt_length(t.duration_ms)],
          ["Rating", t.rating ? "#{@config['glyphs', 'star']} x#{t.rating}" : "unrated"],
          ["Path", t.physical_path],
        ]
        rows << ["Archive entry", t.archive_entry] unless t.archive_entry.to_s.empty?
        rows << ["Subtune", t.subtune_index] if t.subtune_index.to_i.positive?
        flags = [("missing" if t.missing == 1), ("errored" if t.errored == 1)].compact
        rows << ["Status", flags.join(", ")] unless flags.empty?
        rows << ["Played", stats[:count].zero? ? "never" :
          "#{stats[:count]}x, #{fmt_length(stats[:total_played_ms])} total (last #{stats[:last_played_at]})"]

        lines = rows.map { |label, value| "#{label}: #{value.nil? || value.to_s.empty? ? '—' : value}" }
        hint = "[i/esc/enter] Close"
        w = [lines.map(&:size).max, hint.size].max + 4
        render_modal(title: "Track Info", w: w, h: lines.size + 5, hint: hint) do |x, y|
          lines.each_with_index { |line, i| @screen.put(y + 2 + i, x + 2, line[0, w - 4], fg: @theme[:primary]) }
        end
      end

      # Lists every hotkey reachable from the currently active pane (pane-local
      # + global, already deduped by Keymap#bindings_for) -- unlike the
      # compact bottom hotkey line, nothing is filtered out here (rate_N
      # actions and nav_up/nav_down are shown too), since this modal exists
      # specifically to be the exhaustive reference the hint line has no
      # room for.
      def render_help_modal
        bindings = @keymap.bindings_for(@active_pane)
        lines = bindings.map do |key, action|
          label = HotkeyLine::LABELS[action] || action.to_s.tr("_", " ")
          "#{key.upcase.ljust(6)} #{label}"
        end
        title = "Hotkeys (#{@active_pane})"
        hint = "[?/esc/enter] Close"

        # Two columns instead of one long list -- left column takes the
        # first (count/2 rounded up) entries, right column the rest, so an
        # odd count leaves the extra row on the left rather than the right.
        rows = (lines.size / 2.0).ceil
        col1 = lines.first(rows)
        col2 = lines.drop(rows)
        col_w = lines.map(&:size).max
        gap = 4
        w = [col_w * 2 + gap, hint.size, title.size].max + 4
        render_modal(title: title, w: w, h: rows + 5, hint: hint) do |x, y|
          rows.times do |i|
            @screen.put(y + 2 + i, x + 2, col1[i][0, col_w], fg: @theme[:primary]) if col1[i]
            @screen.put(y + 2 + i, x + 2 + col_w + gap, col2[i][0, col_w], fg: @theme[:primary]) if col2[i]
          end
        end
      end

      # Live preview: @theme already reflects Theme::ALL_IDS[@theme_picker_index]
      # (see #move_theme_preview), so the highlighted row is drawn with that
      # same theme's own selection colors -- the picker doubles as a swatch.
      def render_theme_picker_modal
        names = Theme::ALL_IDS.map { |id| Theme[id][:name] }
        hint = "[up/down] Preview  [enter] Select  [esc] Cancel"
        title = "Select Theme"
        w = [names.map(&:size).max, hint.size, title.size].max + 6
        render_modal(title: title, w: w, h: names.size + 5, hint: hint) do |x, y|
          names.each_with_index do |name, i|
            selected = i == @theme_picker_index
            bg = selected ? @theme[:selection_bg] : nil
            fg = selected ? @theme[:selection_text] : @theme[:text]
            @screen.put(y + 2 + i, x + 1, " " * (w - 2), bg: bg) if selected
            @screen.put(y + 2 + i, x + 2, name[0, w - 4], fg: fg, bg: bg, bold: selected)
          end
        end
      end

      def render_config_error_modal
        max_w = [@screen.cols - 2, 100].min
        return if max_w < 8 || @screen.rows < 5

        inner_w = max_w - 4
        raw_lines = [
          "Last known good configuration remains active.",
          *@config_error.message.lines.map(&:chomp),
        ]
        lines = raw_lines.flat_map do |line|
          line.empty? ? [""] : line.scan(/.{1,#{inner_w}}/)
        end
        max_lines = [@screen.rows - 5, 1].max
        lines = lines.first(max_lines)
        hint = "[esc/enter] Keep last known good config"
        w = max_w
        render_modal(title: "Configuration Error", w: w, h: lines.size + 4,
                     hint: hint, hint_bg: @theme[:surface]) do |x, y|
          lines.each_with_index do |line, index|
            color = index.zero? ? @theme[:warning] : @theme[:error]
            @screen.put(y + 1 + index, x + 2, line[0, w - 4], fg: color,
                        bg: @theme[:surface], bold: index.zero?)
          end
        end
      end

      def fmt_length(ms)
        return "unknown" unless ms
        total = ms / 1000
        format("%d:%02d", total / 60, total % 60)
      end

      def draw_box(x, y, w, h, active:, title:)
        color = active ? @theme[:border_focus] : @theme[:border]
        tl, tr, bl, br, hz, vt = active ? %w[╔ ╗ ╚ ╝ ═ ║] : %w[┌ ┐ └ ┘ ─ │]
        @screen.put(y, x, "#{tl}#{hz * (w - 2)}#{tr}", fg: color)
        (1...(h - 1)).each do |i|
          @screen.put(y + i, x, vt, fg: color)
          @screen.put(y + i, x + w - 1, vt, fg: color)
        end
        @screen.put(y + h - 1, x, "#{bl}#{hz * (w - 2)}#{br}", fg: color)
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
        @needs_render = true
        rows, cols = TTY::Screen.size
        @screen.resize(rows, cols)
      end
    end
  end
end
