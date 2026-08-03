# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class ListRowRendererTest < Minitest::Test
  def setup
    @track = RubyPlayer::Track.new(id: 7, title: 'Song', artist: 'Band', duration_ms: 65_000)
    @formatter = lambda do |track, fmt|
      fmt.line(fmt.text(track.title, bold: true),
               fmt.duration(track.duration_ms, fg: :text_muted),
               fmt.text(track.artist, italic: true))
    end
  end

  def test_track_builds_existing_segment_row_shape
    row = RubyPlayer::UI::ListRowRenderer.track(
      @track, formatter: @formatter, star_glyph: '★'
    )

    assert_equal :track, row[:type]
    assert_same @track, row[:track]
    assert_equal 'Song 1:05 Band', row[:text]
    assert row[:segments].first[:bold]
    assert_equal :text_muted, row[:segments][2][:fg]
  end

  def test_render_track_clips_segments_and_preserves_styles
    row = RubyPlayer::UI::ListRowRenderer.track(
      @track, formatter: @formatter, star_glyph: '★'
    )
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 2, cols: 8)

    RubyPlayer::UI::ListRowRenderer.render_track(
      screen, row, x: 0, y: 0, w: 8, selected: false, bg: nil,
                   theme: RubyPlayer::Theme::DEFAULT
    )
    cells = screen.instance_variable_get(:@back)[0]

    assert_equal 'Song 1:0', cells.map(&:ch).join
    assert cells[0].bold
    assert_equal RubyPlayer::Theme::DEFAULT[:text_muted], cells[5].fg
  end

  def test_selected_row_uses_selection_palette
    row = RubyPlayer::UI::ListRowRenderer.track(
      @track, formatter: @formatter, star_glyph: '★'
    )
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 1, cols: 20)

    RubyPlayer::UI::ListRowRenderer.render_track(
      screen, row, x: 0, y: 0, w: 20, selected: true,
                   bg: RubyPlayer::Theme::DEFAULT[:selection_bg], theme: RubyPlayer::Theme::DEFAULT
    )
    cell = screen.instance_variable_get(:@back)[0][0]

    assert_equal RubyPlayer::Theme::DEFAULT[:selection_text], cell.fg
    assert_equal RubyPlayer::Theme::DEFAULT[:selection_bg], cell.bg
    assert cell.bold
  end

  def test_header_line_fills_available_width
    assert_equal '--- Album ---', RubyPlayer::UI::ListRowRenderer.header_line('Album', 13)
    assert_equal '--- Al', RubyPlayer::UI::ListRowRenderer.header_line('Album', 6)
  end
end
