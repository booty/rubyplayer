require 'test_helper'
require 'stringio'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/ui/chip_live_view'
require 'rubyplayer/ui/chip_tracker_view'

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

  def test_chiptune_technical_section_shows_hardware_instead_of_audio_encoding_facts
    tune = RubyPlayer::Track.new(id: 3, title: 'Chip song', format: 'vgm')
    modal = RubyPlayer::UI::NowPlayingModal.new(tune, extras: {
                                                  'system' => 'Sega Mega Drive', 'sound_chips' => 'YM2612 + SN76489',
                                                  'voice_layout' => '6 FM (FM 6 can use PCM); 3 tone + 1 noise',
                                                  'vgm_version' => '1.50', 'chip_clocks' => 'YM2612 7670454 Hz',
                                                  'intro_length_ms' => '12300', 'loop_length_ms' => '45000'
                                                })
    text, = render_modal(modal, rows: 40)

    assert_includes text, 'System: Sega Mega Drive'
    assert_includes text, 'Chips: YM2612 + SN76489'
    assert_includes text, 'Voices: 6 FM (FM 6 can use PCM); 3 tone + 1 noise'
    assert_includes text, 'VGM version: 1.50'
    assert_includes text, 'Chip clocks: YM2612 7670454 Hz'
    assert_includes text, 'Intro: 0:12'
    assert_includes text, 'Loop: 0:45'
    refute_includes text, 'Bit rate:'
  end

  def test_fresh_metadata_replaces_stored_tags_and_invalid_track_totals_are_ignored
    modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: { 'track_total' => '12' })
    modal.update(artist: nil, track_number: 8, extra: { 'track_total' => '2' })
    text, = render_modal(modal)

    refute_includes text, 'Artist: Artist'
    assert_includes text, 'Track: 8'
    refute_includes text, '8 of 2'
  end

  def test_live_page_fills_the_screen_without_art_and_keeps_track_context
    view = RubyPlayer::UI::ChipLiveView.new
    modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: {
                                                  'sound_chips' => 'YM2612 + SN76489',
                                                  'system' => 'Sega Mega Drive'
                                                }, page: :live, chip_view: view, live_kind: :vgm)
    view.update(RubyPlayer::Vgm::Snapshot.new(
                  generation: 1, revision: 0, sample: 44_100, status: :ready,
                  message: nil, loop_count: 2, chips: [], warnings: []
                ))
    modal.update_chip(now_sample: 88_200, mute_mask: 0)

    text, art = render_modal(modal, rows: 28, cols: 160)

    assert_includes text, 'Song — Artist · VGM LIVE'
    assert_includes text, '0:02 · Loop 2'
    assert_nil art
  end

  def test_live_page_order_depends_on_playback_kind
    vgm = RubyPlayer::UI::NowPlayingModal.new(track, extras: {}, live_kind: :vgm, page: :live)

    assert_equal %i[live tracker], vgm.live_pages
    assert_predicate vgm, :live_page?
    assert_equal :tracker, vgm.next_live_page
    vgm.page = :tracker

    assert_predicate vgm, :live_page?
    assert_nil vgm.next_live_page

    hes = RubyPlayer::UI::NowPlayingModal.new(track, extras: {}, live_kind: :hes, page: :live)

    assert_equal %i[live tracker], hes.live_pages
    %i[spc gbs nsf].each do |kind|
      modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: {}, live_kind: kind, page: :live)

      assert_equal [:live], modal.live_pages
      assert_nil modal.next_live_page
    end

    ordinary = RubyPlayer::UI::NowPlayingModal.new(track, extras: {}, page: :live)

    assert_empty ordinary.live_pages
    assert_equal :info, ordinary.page
    vgm.page = :unsupported

    assert_equal :info, vgm.page
  end

  def test_live_hint_names_what_o_does_on_each_kind
    hints = %i[vgm hes gbs nsf].to_h do |kind|
      modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: {}, live_kind: kind, page: :live)
      screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 28, cols: 160)
      captured_hint = nil
      modal.render(screen, theme: RubyPlayer::Theme::DEFAULT, min_art_rows: 3,
                           frame: ->(hint:, **_options) { captured_hint = hint })
      [kind, captured_hint]
    end

    assert_includes hints[:vgm], '[o] Tracker'
    refute_includes hints[:vgm], '[o/esc/enter] Close'
    assert_includes hints[:hes], '[o] Tracker'
    assert_includes hints[:gbs], '[o/esc/enter] Close'
    assert_includes hints[:nsf], '[o/esc/enter] Close'
  end

  def test_tracker_page_uses_full_screen_frame_and_its_own_hint
    vgm = RubyPlayer::Track.new(id: 3, title: 'Chip song', format: 'vgm')
    modal = RubyPlayer::UI::NowPlayingModal.new(vgm, extras: {}, live_kind: :vgm,
                                                     tracker_view: RubyPlayer::UI::ChipTrackerView.new, page: :tracker)
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 15, cols: 40)
    captured_hint = nil
    frame = lambda do |w:, h:, hint:, **_options, &draw|
      assert_equal 38, w
      assert_equal 13, h
      draw.call(1, 1)
      captured_hint = hint
    end
    art = modal.render(screen, theme: RubyPlayer::Theme::DEFAULT, frame: frame, min_art_rows: 3)
    text = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n")

    assert_includes text, 'VGM TRACKER'
    assert_includes captured_hint, '[←/→] Channels'
    assert_nil art
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
