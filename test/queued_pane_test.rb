# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class QueuedPaneTest < Minitest::Test
  def setup
    @config = RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false)
    @upcoming = []
    @history = []
    @pane = RubyPlayer::UI::QueuedPane.new(
      config: @config,
      upcoming_source: -> { @upcoming },
      history_source: -> { @history }
    )
  end

  def track(id, title:, duration_ms:, artist: 'Artist')
    RubyPlayer::Track.new(id: id, title: title, artist: artist, duration_ms: duration_ms)
  end

  def texts(height = 12)
    @pane.display_rows(height).map { |row| row[:text] }
  end

  def test_header_counts_full_queue_and_sums_known_duration
    @upcoming = [
      track(1, title: 'One', duration_ms: 60_000),
      track(2, title: 'Two', duration_ms: 65_000)
    ]
    @pane.reload!

    assert_equal 'Upcoming (2/2:05)', texts.first
  end

  def test_unknown_duration_appends_marker_to_known_sum
    @upcoming = [
      track(1, title: 'Known', duration_ms: 7_425_000),
      track(2, title: 'Unknown', duration_ms: nil)
    ]
    @pane.reload!

    assert_equal 'Upcoming (2/123:45 + ??)', texts.first
  end

  def test_all_unknown_duration_starts_with_zero_known_sum
    @upcoming = [track(1, title: 'Unknown', duration_ms: nil)]
    @pane.reload!

    assert_equal 'Upcoming (1/0:00 + ??)', texts.first
  end

  def test_previous_keeps_three_newest_events_and_duplicates
    repeated = track(1, title: 'Again', duration_ms: 60_000)
    @history = [
      repeated,
      repeated,
      track(2, title: 'Older', duration_ms: 60_000),
      track(3, title: 'Too old', duration_ms: 60_000)
    ]
    @pane.reload!

    previous = @pane.display_rows(12).drop_while { |row| row[:text] != 'Previously' }.drop(1)

    assert_equal(%w[Again Again Older], previous.map { |row| row[:track].title })
  end

  def test_overflow_uses_last_upcoming_row_for_exact_hidden_count
    @upcoming = Array.new(6) do |index|
      track(index, title: "Song #{index}", duration_ms: 60_000)
    end
    @history = Array.new(3) do |index|
      track(20 + index, title: "Past #{index}", duration_ms: 60_000)
    end
    @pane.reload!

    assert_equal [
      'Upcoming (6/6:00)', 'Song 0 1:00 Artist', '+ 5 more',
      'Previously', 'Past 0 1:00 Artist', 'Past 1 1:00 Artist', 'Past 2 1:00 Artist'
    ], texts(7)
  end

  def test_short_height_preserves_previous_before_upcoming
    @upcoming = [track(1, title: 'Next', duration_ms: 60_000)]
    @history = Array.new(3) do |index|
      track(10 + index, title: "Past #{index}", duration_ms: 60_000)
    end
    @pane.reload!

    assert_equal [
      'Previously', 'Past 0 1:00 Artist', 'Past 1 1:00 Artist', 'Past 2 1:00 Artist'
    ], texts(4)
  end

  def test_exactly_fitting_upcoming_rows_do_not_add_overflow_row
    @upcoming = [
      track(1, title: 'One', duration_ms: 60_000),
      track(2, title: 'Two', duration_ms: 60_000)
    ]
    @pane.reload!

    overflow = texts(5).any? { |text| text.start_with?('+ ') }

    refute overflow
  end

  def test_empty_sections_have_contextual_messages
    assert_equal [
      'Upcoming (0/0:00)', 'Queue empty',
      'Previously', 'No playback history yet'
    ], texts(4)
  end

  def test_navigation_selects_upcoming_tracks_but_not_history
    @upcoming = Array.new(4) do |index|
      track(index, title: "Song #{index}", duration_ms: 60_000)
    end
    @history = Array.new(3) do |index|
      track(20 + index, title: "Past #{index}", duration_ms: 60_000)
    end
    @pane.reload!

    assert_same @upcoming[0], @pane.selected_track
    @pane.handle_action(:nav_down)

    assert_same @upcoming[1], @pane.selected_track

    4.times { @pane.handle_action(:nav_down) }

    assert_same @upcoming[3], @pane.selected_track
    refute_includes @upcoming, @history.first
  end

  def test_selected_upcoming_track_scrolls_without_hiding_history
    @upcoming = Array.new(6) do |index|
      track(index, title: "Song #{index}", duration_ms: 60_000)
    end
    @history = Array.new(3) do |index|
      track(20 + index, title: "Past #{index}", duration_ms: 60_000)
    end
    @pane.reload!
    4.times { @pane.handle_action(:nav_down) }

    rows = @pane.display_rows(7)
    row_texts = rows.map { |row| row[:text] }

    assert_includes row_texts, 'Song 4 1:00 Artist'
    assert_includes row_texts, 'Previously'
    past_titles = rows.last(3).map { |row| row[:track].title }

    assert_equal ['Past 0', 'Past 1', 'Past 2'], past_titles
  end

  def test_render_draws_decorative_headers_and_compact_rows
    @upcoming = [track(1, title: 'Song', duration_ms: 60_000, artist: 'Band')]
    @pane.reload!
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 8, cols: 30)

    @pane.render(screen, x: 0, y: 0, w: 30, h: 8, theme: RubyPlayer::Theme::DEFAULT)
    lines = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }

    assert_includes lines[0], '--- Upcoming (1/1:00)'
    assert_includes lines[1], 'Song 1:00 Band'
    assert_includes lines[2], '--- Previously'
  end

  def test_render_highlights_selected_upcoming_row_only_when_active
    @upcoming = [
      track(1, title: 'First', duration_ms: 60_000),
      track(2, title: 'Second', duration_ms: 60_000)
    ]
    @history = [track(3, title: 'Past', duration_ms: 60_000)]
    @pane.reload!
    @pane.handle_action(:nav_down)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 8, cols: 30)
    theme = RubyPlayer::Theme::DEFAULT

    @pane.render(screen, x: 0, y: 0, w: 30, h: 8, active: true, theme: theme)
    back = screen.instance_variable_get(:@back)

    selected_bg = theme[:selection_bg]
    selected_row = back[2].any? { |cell| cell.bg == selected_bg }
    history_row = back[4].any? { |cell| cell.bg == selected_bg }

    assert selected_row
    refute history_row
  end
end
