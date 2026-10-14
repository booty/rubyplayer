require 'test_helper'
require_relative 'support/app_test_support'

class AppArtworkTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_losing_art_hides_and_frees_the_terminal_image
    play_with_cover_art
    @app.handle_key('v')
    out = use_screen
    @app.render_if_needed

    assert_equal 1, out.string.scan("\e_Ga=t,").size
    assert_equal 1, out.string.scan("\e_Ga=p,").size

    @app.send(:set_art, nil)
    @app.render_if_needed

    assert_equal 1, out.string.scan("\e_Ga=d,d=I,").size
    assert_equal 1, out.string.scan("\e_Ga=d,d=i,").size
    assert_equal 1, out.string.scan("\e_Ga=p,").size
  end

  def test_all_art_modes_reuse_the_same_terminal_upload
    play_with_cover_art
    out = use_screen(rows: 40, cols: 138)

    %i[inset pane corner].each do |mode|
      @app.instance_variable_set(:@art_mode, mode)
      @app.send(:invalidate_screen!)
      @app.render_if_needed

      refute_nil art_region, "#{mode} mode has an art region"
    end

    assert_equal 1, out.string.scan("\e_Ga=t,").size
    assert_equal 3, out.string.scan("\e_Ga=p,").size
  end

  def test_shrinking_without_an_art_region_hides_then_growing_reuses_upload
    play_with_cover_art
    @app.handle_key('v')
    out = use_screen(rows: 40, cols: 138)
    @app.render_if_needed

    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: 24, cols: 60))
    @app.send(:invalidate_screen!)
    @app.render_if_needed

    assert_nil art_region
    assert_equal 1, out.string.scan("\e_Ga=d,d=i,").size

    @app.instance_variable_set(:@screen, RubyPlayer::UI::Screen.new(out: out, rows: 40, cols: 138))
    @app.send(:invalidate_screen!)
    @app.render_if_needed

    assert_equal 1, out.string.scan("\e_Ga=t,").size
    assert_equal 2, out.string.scan("\e_Ga=p,").size
  end

  def test_resize_settling_handles_art_before_a_region_is_available
    play_with_cover_art
    @app.handle_key('v')
    out = use_screen
    @app.instance_variable_set(:@art_region, nil)
    @app.instance_variable_set(:@last_resize_at, Process.clock_gettime(Process::CLOCK_MONOTONIC))
    @app.send(:invalidate_screen!)

    @app.render_if_needed

    assert_nil art_region
    refute_includes out.string, "\e_Ga=p,"
  end

  def test_every_overlay_hides_and_restores_the_current_art_placement
    play_with_cover_art
    @app.handle_key('v')
    out = use_screen
    @app.render_if_needed
    image_commands = out.string.scan("\e_Ga=t,").size
    placement_commands = out.string.scan("\e_Ga=p,").size
    hide_commands = 0
    overlay_flags = %i[pending_delete pending_missing_purge info_track show_help theme_picker
                       config_error playlist_modal name_prompt pending_playlist_delete]

    overlay_flags.each do |flag|
      @app.instance_variable_set("@#{flag}", true)
      @app.instance_variable_set(:@art_dirty, true)
      @app.send(:emit_art)
      hide_commands += 1

      assert_equal placement_commands, out.string.scan("\e_Ga=p,").size, "placement hidden by #{flag}"
      assert_equal hide_commands, out.string.scan("\e_Ga=d,d=i,").size, "one hide for #{flag}"

      @app.instance_variable_set("@#{flag}", nil)
      @app.instance_variable_set(:@art_dirty, true)
      @app.send(:emit_art)
      placement_commands += 1
    end

    assert_equal image_commands, out.string.scan("\e_Ga=t,").size
    assert_equal placement_commands, out.string.scan("\e_Ga=p,").size
  end

  def test_terminal_cleanup_frees_art_before_leaving_alternate_screen
    play_with_cover_art
    @app.handle_key('v')
    out = use_screen
    @app.render_if_needed

    @app.send(:restore_terminal)

    assert_operator out.string.index("\e_Ga=d,d=I,"), :<, out.string.index("\e[?1049l")
  end

  def test_app_enables_art_for_kitty_environment
    @app.shutdown
    @app = make_app(env: { 'TERM' => 'xterm-kitty' })

    assert @app.instance_variable_get(:@art_supported)
  end

  def test_live_page_hides_then_info_and_close_reuse_same_track_upload
    start_paused_gbs_with_art
    @app.handle_key('v')
    out = use_screen(rows: 40, cols: 138)
    @app.render_if_needed

    assert_graphics_count(out, 'a=t,', 1)

    @app.handle_key('o')
    modal = @app.instance_variable_get(:@now_playing_modal)

    assert_equal [:live], modal.live_pages
    @app.render_if_needed
    uploads = out.string.scan("\e_Ga=t,").size

    assert_equal 1, uploads
    assert_graphics_count(out, 'a=p,', 1)
    assert_graphics_count(out, 'a=d,d=i,', 1)

    @app.handle_key('tab')
    @app.render_if_needed

    assert_graphics_count(out, 'a=t,', uploads)
    assert_graphics_count(out, 'a=p,', 2)

    @app.handle_key('tab')
    @app.render_if_needed

    assert_graphics_count(out, 'a=t,', uploads)
    assert_graphics_count(out, 'a=d,d=i,', 2)

    @app.handle_key('escape')
    @app.render_if_needed

    assert_graphics_count(out, 'a=t,', uploads)
    assert_graphics_count(out, 'a=p,', 3)
  end

  def test_art_placement_keeps_cover_aspect_using_configured_cell_shape
    play_with_cover_art
    @app.instance_variable_set(:@art_mode, :corner)
    out = use_screen(rows: 40, cols: 138)

    RubyPlayer::UI::KittyImage.stub(:tty_cell_size, nil) { @app.render_if_needed }

    cols, rows = out.string[/\e_Ga=p,[^\e]*/].match(/c=(\d+),r=(\d+)/).captures.map(&:to_i)
    region = art_region

    # warrior.jpg is 4:3 and default cells are twice as tall as wide, so
    # the 16x8 corner (square in pixels) letterboxes to 16x6.
    assert_equal [16, 8], region.values_at(:w, :h)
    assert_equal [16, 6], [cols, rows]
  end

  private

  def start_paused_gbs_with_art
    File.binwrite(File.join(@music, 'cover.jpg'), File.binread(File.join(FIXTURES, 'warrior.jpg')))
    track = @app.instance_variable_get(:@library).all_tracks.find do |entry|
      entry.format == 'gbs' && entry.subtune_index == 1
    end
    @app.engine.enqueue_now([track])
    wait_until(timeout: 2, interval: 0.01, failure_message: 'GBS track did not start') do
      @app.engine.state[:track]&.id == track.id && @app.engine.chip_live_kind == :gbs
    end
    @app.engine.toggle_play
    wait_until(timeout: 2, interval: 0.01, failure_message: 'playback did not pause') do
      @app.engine.state[:paused]
    end
    wait_until(timeout: 2, interval: 0.01, failure_message: 'cover art did not load') do
      @app.handle_events
      @app.instance_variable_get(:@art_bytes)
    end
  end

  def assert_graphics_count(out, command, count)
    assert_equal count, out.string.scan("\e_G#{command}").size
  end
end
