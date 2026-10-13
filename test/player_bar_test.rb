# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'rubyplayer/ui/player_bar'

# The Now Playing bar: four rows of track facts and progress beside a
# spectrum as tall as the bar, or one line on short terminals.
class PlayerBarTest < Minitest::Test
  THEME = RubyPlayer::Theme::DEFAULT
  Details = RubyPlayer::UI::PlayerBar::Details

  def setup
    @bar = RubyPlayer::UI::PlayerBar.new(glyphs: RubyPlayer::DEFAULTS['glyphs'], rows: 4)
    @track = RubyPlayer::Track.new(id: 1, title: 'Flash Man', artist: 'Capcom', duration_ms: 120_000)
    @details = Details.new(rating: 4, credits: 'Capcom · Mega Man 2 (1988)', file_facts: 'NSF · 2A03 · 48 kHz stereo')
  end

  def test_height_is_the_configured_rows_plus_border_or_one_line_when_short
    assert_equal 6, @bar.height(40)
    assert_equal 1, @bar.height(29)
  end

  def test_tall_bar_shows_title_rating_state_credits_format_and_progress
    lines = render_inner(state: playing(65_000), details: @details)

    assert_match(/Flash Man .*★★★★ +\S+ playing/, lines[0])
    assert_includes lines[1], 'Capcom · Mega Man 2 (1988)'
    assert_includes lines[2], 'NSF · 2A03 · 48 kHz stereo'
    assert_match(%r{━+─+ 1:05 / 2:00}, lines[3])
  end

  # The spectrum fills every row: a full band reaches the top, a silent one
  # stays blank.
  def test_spectrum_is_as_tall_as_the_bar
    lines = render_inner(state: playing(0), levels: [1.0, 0.0])
    full = RubyPlayer::DEFAULTS['glyphs']['eq_chars'][-1]

    lines.each { |line| assert_equal "#{full * 2}  ", line[-4..], line.inspect }
    assert_equal 1, lines.first.count('│'), 'one separator before the spectrum'
  end

  def test_art_takes_a_square_on_the_left_and_is_reported
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 4, cols: 80)
    region = @bar.render(screen, x: 0, y: 0, w: 80, h: 4, state: playing(0), levels: [], theme: THEME,
                                 details: @details, art: true)

    assert_equal({ x: 1, y: 0, w: 8, h: 4 }, region)
    assert(text(screen).all? { |line| line[1, 8].strip.empty? })
  end

  def test_unknown_duration_and_stopped_and_focus_states
    unknown = { track: RubyPlayer::Track.new(id: 2, title: 'Mystery'), playing: true, paused: false,
                position_ms: 1_000 }

    assert_includes render_inner(state: unknown).last, '0:01 / ?:??'
    assert_includes render_inner(state: { track: nil }).first, 'Nothing playing'
    focus = { focus_sound: RubyPlayer::FocusSound.new(id: 'rain', title: 'Rain', sox_args: []), track: nil }
    lines = render_inner(state: focus)

    assert_includes lines.first, 'Focus — Rain'
    assert_includes lines.join, '∞'
  end

  def test_compact_line_keeps_title_time_rating_and_a_spectrum
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 1, cols: 80)
    @bar.render(screen, x: 0, y: 0, w: 80, h: 1, state: playing(65_000), levels: [1.0], theme: THEME,
                        details: @details)
    line = text(screen).first

    assert_match(%r{Flash Man — Capcom +★★★★ +1:05/2:00}, line)
    assert line.end_with?(RubyPlayer::DEFAULTS['glyphs']['eq_chars'][-1])
  end

  def test_details_name_credits_and_file_facts
    chip = RubyPlayer::Track.new(id: 3, title: 'Opening', artist: 'Jake Kaufman', composer: 'Jake Kaufman',
                                 album: 'Shantae', year: 2002, track_number: 1, format: 'gbs')
    details = Details.for(chip, rating: 5, extras: { 'sound_chips' => 'Game Boy APU',
                                                     'voice_layout' => '2 pulse + 1 wave + 1 noise' })

    assert_equal 'Jake Kaufman · Shantae (2002) · track 1', details.credits
    assert_equal 'GBS · Game Boy APU · 2 pulse + 1 wave + 1 noise', details.file_facts
    song = RubyPlayer::Track.new(id: 4, title: 'Song', artist: 'Band', composer: 'Writer', format: 'm4a')
    details = Details.for(song, rating: nil, extras: { 'codec' => 'aac', 'bit_rate' => '256000',
                                                       'sample_rate' => '44100', 'channels' => '2' })

    assert_equal 'Band · composer Writer', details.credits
    assert_equal 'M4A · AAC · 256 kbps · 44.1 kHz · stereo', details.file_facts
    assert_nil Details.for(RubyPlayer::Track.new(id: 5, title: 'Bare'), rating: nil, extras: {}).credits
  end

  private

  def playing(position_ms) = { track: @track, playing: true, paused: false, position_ms: position_ms }

  def render_inner(state:, levels: [], details: nil, width: 100)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 4, cols: width)
    @bar.render(screen, x: 0, y: 0, w: width, h: 4, state: state, levels: levels, theme: THEME, details: details)
    text(screen)
  end

  def text(screen) = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
end
