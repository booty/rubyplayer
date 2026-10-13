# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

# 0-6 rate the highlighted track in Tracks or Queued; the playing track is
# rated from the Now Playing bar, which shows its rating.
class AppRatingTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    # Wide enough for Queued, and tall enough for the full Now Playing bar.
    use_screen(rows: 30, cols: 160)
  end

  def test_tracks_pane_rates_the_highlighted_track_not_the_playing_one
    start_normal_playback
    playing = @app.engine.state[:track]
    @app.handle_key('down')
    highlighted = @app.tracks_pane.selected_track
    @app.handle_key('4')

    refute_equal playing.id, highlighted.id
    assert_equal 4, library.rating_of(highlighted.id)
    assert_nil library.rating_of(playing.id)
  end

  def test_queued_pane_rates_its_highlighted_track
    start_normal_playback
    @app.handle_key('down')
    @app.handle_key('n') # queue it last
    @app.handle_events
    focus_pane(:queued)
    highlighted = @app.instance_variable_get(:@queued_pane).selected_track
    @app.handle_key('2')

    refute_nil highlighted
    refute_equal @app.engine.state[:track].id, highlighted.id
    assert_equal 2, library.rating_of(highlighted.id)
  end

  def test_now_playing_pane_rates_the_playing_track_and_shows_it
    start_normal_playback
    focus_pane(:now_playing)
    playing = @app.engine.state[:track]
    @app.render

    assert_includes bar_text, 'unrated'
    @app.handle_key('5')
    @app.render

    assert_equal 5, library.rating_of(playing.id)
    assert_includes bar_text, star * 5
    @app.handle_key('0')
    @app.render

    assert_nil library.rating_of(playing.id)
    assert_includes bar_text, 'unrated'
  end

  def test_library_pane_rates_nothing_and_says_where_to_rate
    start_normal_playback
    @app.instance_variable_set(:@active_pane, :library)
    @app.handle_key('3')
    @app.render

    assert_nil library.rating_of(@app.engine.state[:track].id)
    assert_includes @app.instance_variable_get(:@io_out).string, 'Tab to Now Playing to rate the playing track'
  end

  def test_now_playing_pane_rating_without_playback_explains_why
    focus_pane(:now_playing)
    @app.handle_key('1')
    @app.render

    assert_includes @app.instance_variable_get(:@io_out).string, 'Play a library track before rating'
  end

  # The bar is the last Tab stop; navigation keys there leave the lists
  # alone.
  def test_now_playing_bar_is_the_last_tab_stop
    start_normal_playback
    @app.instance_variable_set(:@active_pane, :library)
    visited = Array.new(4) do
      @app.handle_key('tab')
      @app.active_pane
    end

    assert_equal %i[tracks queued now_playing library], visited
    focus_pane(:now_playing)
    before = @app.tracks_pane.selection
    @app.handle_key('down')
    @app.render

    assert_equal before, @app.tracks_pane.selection
    refute_includes back_buffer_lines.first, 'Now Playing', 'no Now Playing column beside the lists'
    assert_includes bar_text, @app.engine.state[:track].title[0, 20]
  end

  # Short terminals get a one-line bar; it is still where the playing track
  # is rated.
  def test_short_terminals_rate_from_a_one_line_bar
    start_normal_playback
    use_screen(rows: 24, cols: 160)
    focus_pane(:now_playing)
    @app.handle_key('2')
    @app.render

    assert_equal 2, library.rating_of(@app.engine.state[:track].id)
    assert_includes back_buffer_lines[24 - 3 - 1 - 1], star * 2
  end

  private

  def library = @app.instance_variable_get(:@library)

  def star = @app.instance_variable_get(:@config)['glyphs', 'star']

  def focus_pane(pane)
    4.times do
      break if @app.active_pane == pane

      @app.handle_key('tab')
    end

    assert_equal pane, @app.active_pane
  end

  def back_buffer_lines
    @app.instance_variable_get(:@screen).instance_variable_get(:@back).map { |row| row.map(&:ch).join }
  end

  # The 6-row Now Playing bar above the status and hotkey rows.
  def bar_text = back_buffer_lines[-10, 6].join("\n")
end
