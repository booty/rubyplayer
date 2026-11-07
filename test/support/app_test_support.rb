require 'tmpdir'
require 'fileutils'
require 'stringio'
require 'rubyplayer/ui/app'

module TestSupport
  module AppTestSupport
    class FakeFocusPlayer
      attr_reader :played, :stop_calls
      attr_accessor :before_play, :stop_error

      def initialize
        @played = []
        @stop_calls = 0
        @playing = false
      end

      def play(sound, sample_rate:)
        @before_play&.call
        @played << sound
        @playing = true
        true
      end

      def read(frames)
        return nil unless @playing

        ([0.0] * frames * RubyPlayer::AudioFormat::CHANNELS).pack('e*')
      end

      def stop
        raise @stop_error if @stop_error

        @stop_calls += 1
        @playing = false
        true
      end
    end

    # Records what App hands the macOS Now Playing helper, without spawning it.
    class FakeMediaKeys
      attr_reader :states, :start_calls, :stop_calls

      def initialize
        @states = []
        @start_calls = 0
        @stop_calls = 0
      end

      def start = @start_calls += 1
      def update(state) = @states << state
      def stop = @stop_calls += 1
    end

    # Every app test with art plays the same fixture cover, and its two
    # ffmpeg transforms (~0.1 s each) gave the same answer each time. One
    # process-wide memo pays for them once; artwork_test.rb exercises the
    # real transforms on its own Artwork instances.
    module SharedCoverTransforms
      STORE = {} # rubocop:disable Style/MutableConstant -- filled lazily, test process only

      def average_color(bytes)
        key = [:accent, bytes.hash]
        STORE.fetch(key) { STORE[key] = super }
      end

      def display_bytes(bytes, max_px:)
        key = [:display, bytes.hash, max_px]
        STORE.fetch(key) { STORE[key] = super }
      end
    end

    def self.included(test_class)
      test_class.const_set(:FakeFocusPlayer, FakeFocusPlayer)
      test_class.const_set(:FakeMediaKeys, FakeMediaKeys)
    end

    def setup
      @tmp = Dir.mktmpdir
      @music = File.join(@tmp, 'music')
      FileUtils.mkdir_p(@music)
      FileUtils.cp(File.join(FIXTURES, 'space-debris.mod'), @music)
      FileUtils.cp(File.join(FIXTURES, 'shantae.gbs'), @music)
      @focus_player = FakeFocusPlayer.new
      @media_keys = FakeMediaKeys.new
      @app = make_app
      @app.scan_paths([@music], wait: true)
    end

    def make_app(env: { 'TERM_PROGRAM' => 'iTerm.app', 'TERM_PROGRAM_VERSION' => '3.5.4' },
                 config_path: File.join(@tmp, 'config.rb'))
      RubyPlayer::UI::App.new(
        config_path: config_path,
        data_path: File.join(@tmp, 'library.sqlite3'),
        null_audio: true, io_out: StringIO.new, focus_player: @focus_player,
        media_keys: @media_keys, env: env
      )
    end

    def teardown
      @app&.shutdown
      FileUtils.remove_entry(@tmp)
    end

    def select_tracks_for(kind)
      select_library_kind(kind)
      @app.handle_key('tab')
    end

    def select_library_kind(kind)
      focus_pane(:library)
      20.times { @app.handle_key('up') }
      index = @app.library_pane.rows.index { |row| row.kind == kind }
      index.times { @app.handle_key('down') }
    end

    def start_normal_playback
      select_tracks_for(:folder)
      @app.handle_key('enter')
      wait_until(timeout: 2, interval: 0.01, failure_message: 'timed out waiting for condition') do
        @app.engine.state[:playing]
      end
    end

    def art_region = @app.art.region

    def library = @app.library

    # Swaps in a Screen of the given size writing to out (fresh by default),
    # as a terminal resize would. The only place tests replace App's output.
    def use_screen(rows: 24, cols: 110, out: StringIO.new)
      @app.instance_variable_set(:@io_out, out)
      @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: rows, cols: cols))
      out
    end

    # Moves focus straight to a pane, skipping the Tab cycle. The only place
    # tests set App's focus directly.
    def focus_pane(pane)
      @app.instance_variable_set(:@active_pane, pane)
    end

    def play_with_cover_art
      File.binwrite(File.join(@music, 'cover.jpg'), File.binread(File.join(FIXTURES, 'warrior.jpg')))
      @app.instance_variable_get(:@art_fetcher).artwork.extend(SharedCoverTransforms)
      start_normal_playback
      # Art resolves on a background thread and lands as an :art_ready event.
      wait_until(timeout: 2, interval: 0.01, failure_message: 'timed out waiting for condition') do
        @app.handle_events
        @app.art.bytes
      end
    end

    def current_theme = @app.instance_variable_get(:@theme)

    def base_theme = @app.instance_variable_get(:@base_theme)

    def seed_playlist_tracks(names)
      lib = @app.library
      root = lib.upsert_folder(parent_id: nil, name: 'PM', path: '/pm', kind: 'dir')
      names.map do |n|
        lib.upsert_track(folder_id: root, physical_path: "/pm/#{n}.vgm", backend: 'gme',
                         format: 'vgm', title: n.upcase, album: 'Al', artist: 'Ar',
                         composer: 'C', track_number: 1, duration_ms: 1000)
      end
    end

    def open_playlist(pid)
      @app.library_pane.rebuild!
      @app.library_pane.select_playlist(pid)
      @app.send(:show_selected_tracks)
      focus_pane(:tracks)
    end

    def show_all_songs_in_tracks_pane
      pane = @app.library_pane
      pane.rebuild!
      pane.instance_variable_set(:@selection, pane.rows.index { |r| r.kind == :all })
      @app.send(:show_selected_tracks)
      focus_pane(:tracks)
    end

    def select_playlist_child(pid)
      @app.library_pane.rebuild!
      @app.library_pane.select_playlist(pid)
      @app.send(:show_selected_tracks)
      focus_pane(:library)
    end

    private

    def force_config_reload
      @app.instance_variable_set(
        :@last_config_check,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 2
      )
      @app.send(:reload_config_if_changed)
    end

    def mark_two_tracks_missing
      library = @app.library
      tracks = library.recently_added.first(2)
      library.mark_missing(track_ids: tracks.map(&:id), folder_ids: [])
      library.recompute_counts!
      @app.library_pane.rebuild!
      tracks
    end

    def back_buffer_text
      back = @app.screen.back_cells
      back.map { |row| row.map(&:ch).join }.join("\n")
    end

    def instrument_flushes
      count = { n: 0 }
      screen = @app.screen
      screen.define_singleton_method(:flush) do
        count[:n] += 1
        super()
      end
      count
    end
  end
end
