require 'test_helper'
require 'stringio'

class NowPlayingModalTest < Minitest::Test
  def track
    RubyPlayer::Track.new(id: 1, title: 'Song', artist: 'Artist', album_artist: 'Album Artist',
                          album: 'Album', composer: 'Composer', year: 1998, track_number: 3, format: 'mp3')
  end

  def render_modal(modal, rows: 24, cols: 100)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
    frame = lambda do |w:, h:, **_options, &draw|
      assert_operator w, :<=, cols - 2
      assert_operator h, :<=, rows - 2
      draw.call(1, 1)
    end
    art = modal.render(screen, theme: RubyPlayer::Theme::DEFAULT, frame: frame, min_art_rows: 3)
    [screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n"), art]
  end

  def test_sections_show_album_track_total_and_source_technical_information
    modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: {
                                                  'track_total' => '12', 'codec' => 'mp3', 'bit_rate' => '320000',
                                                  'sample_rate' => '44100', 'channels' => '2'
                                                })
    text, art = render_modal(modal)

    assert_includes text, 'Artist: Artist'
    assert_includes text, 'Album artist: Album Artist'
    assert_includes text, 'Album: Album'
    assert_includes text, 'Track: 3 of 12'
    assert_includes text, 'Composer: Composer'
    assert_includes text, 'Year: 1998'
    assert_includes text, 'File type: MP3'
    assert_includes text, 'Bit rate: 320 kbps'
    assert_includes text, 'Sample rate: 44.1 kHz'
    assert_includes text, 'Channels: Stereo'
    assert_operator text.index('Technical'), :>, text.index('Album:')
    refute_nil art
  end

  def test_unknown_values_are_omitted_without_guessing_an_album_total_or_bitrate
    sparse = RubyPlayer::Track.new(id: 2, title: 'Chiptune', format: 'gbs', track_number: 7)
    text, = render_modal(RubyPlayer::UI::NowPlayingModal.new(sparse, extras: {}))

    assert_includes text, 'Track: 7'
    refute_includes text, '7 of'
    assert_includes text, 'File type: GBS'
    refute_includes text, 'Bit rate:'
    refute_includes text, 'Artist:'
  end

  def test_sparse_metadata_keeps_artwork_when_the_terminal_has_room
    sparse = RubyPlayer::Track.new(id: 2, title: 'Chiptune', format: 'gbs')
    _, art = render_modal(RubyPlayer::UI::NowPlayingModal.new(sparse, extras: {}), rows: 40)

    refute_nil art
    assert_operator art[:h], :>=, 3
  end

  def test_fresh_metadata_replaces_stored_tags_and_invalid_track_totals_are_ignored
    modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: { 'track_total' => '12' })
    modal.update(artist: nil, track_number: 8, extra: { 'track_total' => '2' })
    text, = render_modal(modal)

    refute_includes text, 'Artist: Artist'
    assert_includes text, 'Track: 8'
    refute_includes text, '8 of 2'
  end

  def test_small_terminals_keep_both_sections_inside_the_modal
    modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: {
                                                  'track_total' => '12', 'codec' => 'mp3', 'bit_rate' => '128000',
                                                  'sample_rate' => '44100', 'channels' => '2', 'bits_per_sample' => '16'
                                                })
    text, art = render_modal(modal, rows: 12, cols: 50)

    assert_includes text, 'Track'
    assert_includes text, 'Song'
    assert_includes text, 'Technical'
    assert_includes text, 'File type: MP3'
    assert_includes text, 'Bit rate: 128 kbps'
    assert_nil art
  end
end
