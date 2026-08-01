require 'test_helper'
require_relative 'support/app_test_support'

class AppRenderingThemeConfigTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_fmt_length_uses_unknown_duration_placeholder
    assert_equal 'unknown', RubyPlayer::UI::App.allocate.send(:fmt_length, nil)
  end

  def test_narrow_layout_renders_only_active_pane
    out = StringIO.new
    @app.instance_variable_set(:@io_out, out)
    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: 20, cols: 71))

    @app.render
    library_frame = @app.instance_variable_get(:@screen).instance_variable_get(:@back)
    assert_includes library_frame[0].map(&:ch).join, 'Library'
    refute_includes library_frame[0].map(&:ch).join, 'Playback Queue'

    @app.handle_key('tab')
    @app.render
    tracks_frame = @app.instance_variable_get(:@screen).instance_variable_get(:@back)
    assert_includes tracks_frame[0].map(&:ch).join, 'Playback Queue · 0'
    refute_includes tracks_frame[0].map(&:ch).join, 'Library'
  end

  def test_two_pane_layout_starts_at_72_columns
    out = StringIO.new
    @app.instance_variable_set(:@io_out, out)
    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: 20, cols: 72))

    @app.render
    title_row = @app.instance_variable_get(:@screen).instance_variable_get(:@back)[0].map(&:ch).join

    assert_includes title_row, 'Library'
    assert_includes title_row, 'Playback Queue · 0'
  end

  def test_folder_stats_query_runs_once_across_frames
    library = @app.instance_variable_get(:@library)
    calls = 0
    library.define_singleton_method(:folder_stats) do
      calls += 1
      super()
    end
    @app.render
    @app.render
    assert_equal 1, calls
    @app.refresh_panes
    @app.render
    assert_equal 2, calls
  end

  def test_status_track_count_refreshes_after_library_change
    library = @app.instance_variable_get(:@library)
    before = library.folder_stats
    @app.render
    assert_includes back_buffer_text, "#{before[:tracks]} tracks in"

    mark_two_tracks_missing
    @app.refresh_panes
    @app.render
    after = library.folder_stats
    refute_equal before[:tracks], after[:tracks]
    assert_includes back_buffer_text, "#{after[:tracks]} tracks in"
  end

  def test_idle_frames_skip_rendering
    flushes = instrument_flushes
    3.times { @app.render_if_needed }
    assert_equal 1, flushes[:n] # only the initial paint
  end

  def test_keypress_marks_frame_dirty
    flushes = instrument_flushes
    @app.render_if_needed
    @app.handle_key('tab')
    2.times { @app.render_if_needed }
    assert_equal 2, flushes[:n]
  end

  def test_bus_events_mark_frame_dirty
    flushes = instrument_flushes
    @app.render_if_needed
    @app.instance_variable_get(:@bus).publish(:queue_changed, items: [])
    @app.handle_events
    2.times { @app.render_if_needed }
    assert_equal 2, flushes[:n]
  end

  def test_status_message_expiry_renders_exactly_once
    clock = { now: 0.0 }
    status = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { clock[:now] })
    @app.instance_variable_set(:@status_line, status)
    flushes = instrument_flushes
    @app.render_if_needed
    status.set_message('hello')
    2.times { @app.render_if_needed }
    assert_equal 2, flushes[:n] # message appeared

    clock[:now] = 10.0
    2.times { @app.render_if_needed }
    assert_equal 3, flushes[:n] # message expired: repaint default once
  end

  def test_playback_animates_every_frame
    start_normal_playback
    flushes = instrument_flushes
    3.times { @app.render_if_needed }
    assert_equal 3, flushes[:n]
  end

  def test_select_timeout_uses_frame_interval_while_playing
    start_normal_playback
    assert_in_delta 1.0 / 30, @app.select_timeout, 0.001
  end

  def test_select_timeout_relaxes_to_idle_poll_when_stopped
    assert_in_delta 0.25, @app.select_timeout, 0.001
  end

  def test_select_timeout_shrinks_to_status_message_expiry
    clock = { now: 0.0 }
    status = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { clock[:now] })
    @app.instance_variable_set(:@status_line, status)
    status.set_message('hi')
    clock[:now] = 4.9
    assert_in_delta 0.1, @app.select_timeout, 0.02
  end

  def test_art_mode_cycles_and_persists
    assert_equal :off, @app.art_mode
    @app.handle_key('v')
    assert_equal :inset, @app.art_mode
    assert_includes File.read(File.join(@tmp, 'config.rb')), 'config.ui.art_mode = "inset"'

    @app.handle_key('v')
    @app.handle_key('v')
    @app.handle_key('v')
    assert_equal :off, @app.art_mode # inset -> pane -> corner -> off
  end

  def test_persisted_art_mode_is_the_next_launch_default
    # The native audio shim allows one instance per process; retire the
    # setup app before booting a second one.
    @app.shutdown
    path = File.join(@tmp, 'art-config.rb')
    File.write(path, "RubyPlayer.configure { |config| config.ui.art_mode = \"pane\" }\n")
    @app = make_app(config_path: path)
    assert_equal :pane, @app.art_mode
  end

  def test_inset_mode_reserves_bottom_of_library_pane
    play_with_cover_art
    @app.handle_key('v') # -> inset
    use_screen
    @app.render

    region = art_region
    refute_nil region
    content_h = 24 - 4
    assert_equal 1, region[:x] # inside the library box border
    assert_equal content_h - 1 - region[:h], region[:y] # docked at pane bottom
  end

  def test_pane_mode_reserves_right_hand_column
    play_with_cover_art
    2.times { @app.handle_key('v') } # -> pane
    use_screen
    @app.render

    region = art_region
    refute_nil region
    art_w = 30 # ui.art_pane_width default
    assert_equal 110 - art_w + 1, region[:x]
    assert_equal 1, region[:y]
  end

  def test_corner_mode_overlays_bottom_right
    play_with_cover_art
    3.times { @app.handle_key('v') } # -> corner
    use_screen
    @app.render

    region = art_region
    refute_nil region
    assert_equal 8, region[:h] # ui.art_corner_rows default
  end

  def test_art_escape_is_emitted_after_flush_and_not_repeated_when_idle
    play_with_cover_art
    @app.handle_key('v') # -> inset
    out = use_screen

    @app.render_if_needed
    assert_equal 1, out.string.scan('1337;File=inline=1').size

    @app.render_if_needed # idle frame: no repaint, no re-emit
    assert_equal 1, out.string.scan('1337;File=inline=1').size
  end

  def test_no_reemit_while_modal_covers_art_then_reemit_on_close
    play_with_cover_art
    @app.handle_key('v')
    out = use_screen
    @app.render_if_needed
    assert_equal 1, out.string.scan('1337;File=inline=1').size

    @app.handle_key('?') # help modal paints over the panes
    @app.render_if_needed
    # While the modal is up the image must not be re-drawn on top of it.
    assert_equal 1, out.string.scan('1337;File=inline=1').size

    @app.handle_key('escape') # closing repaints cells under the art
    @app.render_if_needed
    assert_equal 2, out.string.scan('1337;File=inline=1').size
  end

  def test_no_escape_without_iterm
    @app.shutdown # native audio shim allows one instance per process
    @app = make_app(env: {}, config_path: File.join(@tmp, 'plain-config.rb'))
    @app.scan_paths([@music], wait: true)
    @app.handle_key('v')
    @app.instance_variable_set(:@art_bytes, 'IMG'.b)
    @app.render

    out = @app.instance_variable_get(:@io_out)
    refute_includes out.string, '1337;File'
  end

  def test_now_playing_needs_a_current_track
    @app.handle_key('o')
    refute @app.show_now_playing
  end

  def test_now_playing_modal_shows_art_and_metadata
    play_with_cover_art
    @app.handle_key('o')
    assert @app.show_now_playing

    out = use_screen
    @app.render_if_needed
    assert_includes back_buffer_text, 'Now Playing'
    assert_includes back_buffer_text, @app.engine.state[:track].title[0, 20]
    refute_nil art_region
    assert_equal 1, out.string.scan('1337;File=inline=1').size

    @app.handle_key('escape')
    refute @app.show_now_playing
  end

  def test_now_playing_modal_captures_keys
    play_with_cover_art
    @app.handle_key('o')
    before = @app.active_pane
    @app.handle_key('tab') # swallowed, not pane switch
    assert_equal before, @app.active_pane
    @app.handle_key('o') # o toggles closed
    refute @app.show_now_playing
  end

  def test_art_region_shows_spectrum_while_playing_without_art
    start_normal_playback # @music has no cover image
    @app.handle_key('v') # -> inset
    use_screen
    @app.render

    refute_nil art_region
    refute_includes back_buffer_text, 'no artwork'
    assert(back_buffer_text.each_char.any? { |c| (0x2800..0x28FF).cover?(c.ord) },
           'expected braille meter cells in the art region')
  end

  def test_album_art_tints_the_accent_color
    play_with_cover_art # warrior.jpg -> real average color via ffmpeg
    use_screen
    @app.render

    accent = current_theme[:accent]
    assert_match(/\A#[0-9a-f]{6}\z/, accent)
    refute_equal base_theme[:accent], accent
  end

  def test_accent_reverts_when_playback_stops
    play_with_cover_art
    @app.instance_variable_get(:@bus).publish(:playback_state, playing: false, paused: false)
    @app.handle_events
    use_screen
    @app.render

    assert_same base_theme, current_theme
  end

  def test_art_emission_is_suppressed_during_resize_storm
    play_with_cover_art
    @app.handle_key('v') # -> inset
    out = use_screen
    @app.render_if_needed
    assert_equal 1, out.string.scan('1337;File=inline=1').size

    5.times do
      @app.instance_variable_set(:@resized, true)
      @app.handle_resize
      @app.render_if_needed
    end
    assert_equal 1, out.string.scan('1337;File=inline=1').size, 'no emits mid-storm'

    # Storm over: pretend the settle window has elapsed.
    @app.instance_variable_set(:@last_resize_at, 0.0)
    @app.render_if_needed
    assert_equal 2, out.string.scan('1337;File=inline=1').size, 'one emit after settle'
  end

  def test_off_mode_reserves_nothing
    play_with_cover_art
    use_screen
    @app.render
    assert_nil art_region
  end

  def test_starts_on_the_default_theme
    assert_equal :default, @app.theme_id
  end

  def test_theme_picker_key_opens_the_modal
    @app.handle_key('t')
    assert @app.theme_picker
  end

  def test_scrolling_the_theme_picker_previews_immediately
    @app.handle_key('t')
    before = @app.theme_id
    @app.handle_key('down')
    refute_equal before, @app.theme_id # live preview changed the active theme
    assert @app.theme_picker # still open -- nothing persisted yet
    assert_equal 'default', @app.instance_variable_get(:@config)['ui', 'theme']
  end

  def test_confirming_the_theme_picker_persists_the_previewed_theme
    @app.handle_key('t')
    @app.handle_key('down')
    previewed = @app.theme_id
    @app.handle_key('enter')

    refute @app.theme_picker
    assert_equal previewed, @app.theme_id
    assert_equal previewed.to_s, @app.instance_variable_get(:@config)['ui', 'theme']
  end

  def test_cancelling_the_theme_picker_reverts_the_preview
    @app.handle_key('t')
    @app.handle_key('down')
    refute_equal :default, @app.theme_id
    @app.handle_key('escape')

    refute @app.theme_picker
    assert_equal :default, @app.theme_id
  end

  def test_selecting_a_hex_theme_actually_changes_rendered_colors
    @app.render
    # StringIO#string returns the live internal buffer, not a copy -- capture
    # the length now (an Integer, immune to later mutation) rather than the
    # string object itself, or "before" would grow along with "after".
    before_len = @app.instance_variable_get(:@io_out).string.size

    @app.handle_key('t')
    @app.handle_key('down') # preview the first named (hex) theme
    @app.render
    themed_out = @app.instance_variable_get(:@io_out).string[before_len..]

    border_hex = RubyPlayer::Theme[@app.theme_id][:border_focus].delete('#').scan(/../).map { |h| h.to_i(16) }
    assert_includes themed_out, "38;2;#{border_hex.join(';')}m"
  end

  def test_theme_picker_wraps_around_the_list
    @app.handle_key('t')
    @app.handle_key('up') # one before :default wraps to the last theme
    assert_equal RubyPlayer::Theme::ALL_IDS.last, @app.theme_id
  end

  def test_invalid_hot_reload_keeps_active_config_and_shows_modal
    config_path = File.join(@tmp, 'config.rb')
    File.write(config_path, <<~RUBY)
      RubyPlayer.configure { |config| config.ui.theme = "ocean_mist" }
    RUBY
    force_config_reload
    assert_equal :ocean_mist, @app.theme_id

    File.write(config_path, "RubyPlayer.configure do |config|\n")
    File.utime(Time.now + 3, Time.now + 3, config_path)
    force_config_reload

    assert_instance_of RubyPlayer::ConfigError, @app.config_error
    assert_equal :ocean_mist, @app.theme_id
    before = @app.active_pane
    @app.handle_key('tab')
    assert_equal before, @app.active_pane

    @app.render
    output = @app.instance_variable_get(:@io_out).string
    assert_includes output, 'Configuration Error'
    assert_includes output, 'SyntaxError'
    assert_includes output, 'config.rb'
  end

  def test_config_error_modal_dismisses_and_corrected_save_clears_it
    config_path = File.join(@tmp, 'config.rb')
    File.write(config_path, "RubyPlayer.configure do |config|\n")
    File.utime(Time.now + 2, Time.now + 2, config_path)
    force_config_reload
    refute_nil @app.config_error

    @app.handle_key('escape')
    assert_nil @app.config_error

    File.write(config_path, <<~RUBY)
      RubyPlayer.configure { |config| config.ui.theme = "amber_navy" }
    RUBY
    File.utime(Time.now + 4, Time.now + 4, config_path)
    force_config_reload

    assert_nil @app.config_error
    assert_equal :amber_navy, @app.theme_id
  end

  def test_config_error_modal_keeps_wrapped_message_content_visible
    message = "#{'x' * 70}VISIBLE_SUFFIX"
    @app.instance_variable_set(
      :@config_error,
      RubyPlayer::ConfigError.new(path: 'config.rb', message: message)
    )

    @app.render

    screen = @app.instance_variable_get(:@screen)
    rendered = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n")
    assert_includes rendered, 'VISI'
    assert_includes rendered, 'BLE_SUFFIX'
  end

  def test_startup_fallback_error_is_available_to_modal
    path = File.join(@tmp, 'fallback-config.rb')
    previous = File.join(@tmp, 'config-previous.rb')
    File.write(previous, <<~RUBY)
      RubyPlayer.configure { |config| config.ui.theme = "ocean_mist" }
    RUBY
    File.write(path, "RubyPlayer.configure do |config|\n")
    @app.shutdown
    @app = nil
    fallback_app = RubyPlayer::UI::App.new(
      config_path: path, data_path: File.join(@tmp, 'fallback.sqlite3'),
      null_audio: true, io_out: StringIO.new, focus_player: FakeFocusPlayer.new
    )

    assert_instance_of RubyPlayer::ConfigError, fallback_app.config_error
    assert_equal :ocean_mist, fallback_app.theme_id
  ensure
    fallback_app&.shutdown
  end
end
