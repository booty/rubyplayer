require 'test_helper'
require_relative 'support/app_test_support'
require_relative 'support/vgm_builder'

class AppNowPlayingTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_existing_chiptune_track_refreshes_hardware_details_without_a_rescan
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'gbs' }
    # Existing libraries have no cached hardware extras from older scans.
    library.replace_track_metadata(track.id, {})
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    @app.handle_events
    use_screen(rows: 40, cols: 110)
    @app.handle_key('o')
    # GBS opens on the live page; the refreshed details are on Info.
    @app.handle_key('tab') if @app.instance_variable_get(:@now_playing_page) == :live

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    wait_until do
      @app.handle_events
      @app.render
      back_buffer_text.include?('Chips: Game Boy APU')
    end

    assert_includes back_buffer_text, 'Voices: 2 pulse + 1 wave + 1 noise'
    assert_includes back_buffer_text, 'System:'
    refute_includes back_buffer_text, 'Bit rate:'
  end

  # Play/pause, next, previous, and seek work from Now Playing (Info or
  # Live) without closing it; the popup follows the new track.
  def test_playback_keys_work_without_closing_now_playing
    tracks = open_now_playing_on_two_gbs_tracks
    @app.handle_key('space')
    wait_until { @app.engine.state[:paused] }

    assert @app.instance_variable_get(:@show_now_playing)
    @app.handle_key('space')
    wait_until { !@app.engine.state[:paused] }
    @app.handle_key(']')
    wait_until { @app.engine.state[:position_ms].to_i >= 5_000 }
    @app.handle_key('>')
    wait_until { @app.engine.state[:track]&.id == tracks.last.id }
    @app.handle_events

    assert @app.instance_variable_get(:@show_now_playing)
    assert @app.instance_variable_get(:@now_playing_modal).matches?(tracks.last)
  end

  # Formats without a live page keep the plain Info popup.
  def test_tracks_without_live_state_have_no_live_page
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'mod' }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    @app.handle_events
    use_screen(rows: 40, cols: 110)
    @app.handle_key('o')
    @app.render

    refute_includes back_buffer_text, 'Info / Live'
    @app.handle_key('tab')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
  end

  # SPC tracks scan as backend 'snes_spc'; the popup must still refresh their
  # hardware details like libgme-backed tracks.
  def test_spc_track_refreshes_hardware_details_without_a_rescan
    FileUtils.cp(File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc'), @music)
    @app.scan_paths([@music], wait: true)
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'spc' }

    assert_equal 'snes_spc', track.backend
    library.replace_track_metadata(track.id, {})
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    @app.handle_events
    use_screen(rows: 40, cols: 110)
    @app.handle_key('o')
    # SPC opens on the live page; the refreshed details are on Info.
    @app.handle_key('tab') if @app.instance_variable_get(:@now_playing_page) == :live

    wait_until do
      @app.handle_events
      @app.render
      back_buffer_text.include?('Chips: S-DSP')
    end
  end

  def test_popup_loads_fresh_file_tags_and_technical_details_for_an_existing_library_track
    path = File.join(@tmp, 'tagged.mp3')
    system('ffmpeg', '-hide_banner', '-loglevel', 'error',
           '-f', 'lavfi', '-i', 'sine=frequency=440:duration=10', '-b:a', '128k',
           '-metadata', 'title=Fresh title', '-metadata', 'artist=Tagged Artist',
           '-metadata', 'album=Tagged Album', '-metadata', 'track=3/12', path, exception: true)
    library = @app.instance_variable_get(:@library)
    folder = library.upsert_folder(parent_id: nil, name: 'tagged', path: @tmp, kind: 'dir')
    id = library.upsert_track(folder_id: folder, physical_path: path, backend: 'ffmpeg',
                              format: 'mp3', title: 'Old title')
    @app.engine.enqueue_now([library.find_track(id)])
    wait_until { @app.engine.state[:track]&.id == id }
    @app.handle_events
    use_screen(cols: 110)
    @app.handle_key('o')
    wait_until do
      @app.handle_events
      @app.render
      back_buffer_text.include?('Artist: Tagged Artist')
    end

    assert_includes back_buffer_text, 'Fresh title'
    assert_includes back_buffer_text, 'Album: Tagged Album'
    assert_includes back_buffer_text, 'Track: 3 of 12'
    assert_includes back_buffer_text, 'File type: MP3'
    assert_includes back_buffer_text, 'Bit rate: 128 kbps'
  end

  def test_popup_follows_track_changes_and_ignores_late_metadata_for_the_old_track
    start_normal_playback
    @app.handle_events
    @app.handle_key('o')
    old_modal = @app.instance_variable_get(:@now_playing_modal)
    old_id = @app.engine.state[:track].id
    next_track = @app.instance_variable_get(:@library).all_tracks.find { |track| track.id != old_id }
    @app.engine.enqueue_end([next_track])
    @app.engine.skip
    wait_until { @app.engine.state[:track] && @app.engine.state[:track].id != old_id }
    @app.handle_events
    @app.instance_variable_get(:@bus).publish(:now_playing_metadata_ready, modal: old_modal,
                                                                           metadata: { title: 'Stale metadata' })
    @app.handle_events
    use_screen
    @app.render

    assert_includes back_buffer_text, @app.engine.state[:track].title[0, 20]
    refute_includes back_buffer_text, 'Stale metadata'
    # GBS tracks open on their live page; others on Info.
    live = @app.instance_variable_get(:@now_playing_page) == :live

    assert_includes back_buffer_text, live ? 'GBS LIVE' : 'Technical'
  end

  def test_short_popup_keeps_technical_rows_above_the_real_close_hint_and_border
    track = RubyPlayer::Track.new(id: 1, title: 'Song', artist: 'Artist', album: 'Album', format: 'mp3')
    modal = RubyPlayer::UI::NowPlayingModal.new(track, extras: {
                                                  'codec' => 'mp3', 'bit_rate' => '128000',
                                                  'sample_rate' => '44100', 'channels' => '2'
                                                })
    [10, 8].each do |height|
      use_screen(rows: height, cols: 80)
      screen = @app.instance_variable_get(:@screen)
      modal.render(screen, theme: current_theme, frame: @app.method(:render_modal), min_art_rows: 3)
      rows = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }
      bitrate_row = rows.index { |row| row.include?('Bit rate: 128 kbps') }
      hint_row = rows.index { |row| row.include?('[o/esc/enter] Close') }

      refute_nil bitrate_row
      refute_nil hint_row
      assert_operator bitrate_row, :<, hint_row
      assert_match(/[└┘╚╝]/, rows[height - 2])
      assert_empty rows.last.strip
    end
  end

  def test_vgm_modal_defaults_to_live_and_tab_suspends_or_resumes_telemetry
    start_live_vgm_track
    use_screen(rows: 32, cols: 110)
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    assert @app.instance_variable_get(:@vgm_telemetry_controller).instance_variable_get(:@visible)
    before_selection = @app.tracks_pane.selection
    @app.handle_key('down')

    assert_equal before_selection, @app.tracks_pane.selection

    controller = @app.instance_variable_get(:@vgm_telemetry_controller)
    wait_for_live_vgm_rows(controller)
    @app.handle_key('tab')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    refute controller.instance_variable_get(:@visible)
    @app.handle_key('tab')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    @app.handle_key('o')

    assert_equal :tracker, @app.instance_variable_get(:@now_playing_page)
    assert @app.show_now_playing
    @app.handle_key('o')

    refute @app.show_now_playing
    refute controller.instance_variable_get(:@visible)
  end

  def test_vgm_page_cycle_and_info_return
    start_live_vgm_track
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    @app.handle_key('o')

    assert_equal :tracker, @app.instance_variable_get(:@now_playing_page)
    @app.handle_key('tab')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    @app.handle_key('tab')

    assert_equal :tracker, @app.instance_variable_get(:@now_playing_page)
    @app.handle_key('o')

    refute @app.show_now_playing
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
  end

  def test_tracker_keeps_playback_keys_and_escape_closes_it
    start_live_vgm_track
    @app.handle_key('o')
    @app.handle_key('o')
    @app.handle_key('space')
    wait_until { @app.engine.state[:paused] }

    assert_equal :tracker, @app.instance_variable_get(:@now_playing_page)
    assert @app.show_now_playing
    @app.handle_key('escape')

    refute @app.show_now_playing
  end

  def test_o_closes_info_for_a_track_without_live_pages
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'mod' }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    @app.handle_events
    @app.handle_key('o')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    @app.handle_key('o')

    refute @app.show_now_playing
  end

  # The fixture declares a YM2612 and an SN76489: libgme voices FM 1-6,
  # PCM, and the PSG as one.
  def test_vgm_live_keys_mute_and_solo_the_selected_channel
    start_live_vgm_track
    use_screen(rows: 40, cols: 160)
    @app.handle_key('o')
    wait_for_live_vgm_rows(@app.instance_variable_get(:@vgm_telemetry_controller))
    @app.handle_key('m')

    assert_equal 0b1, @app.engine.voice_mute_mask
    @app.render

    assert_match(/^.*1 FM 1 .* M\b/, back_buffer_text)
    @app.handle_key('m')

    assert_equal 0, @app.engine.voice_mute_mask
    @app.handle_key('s')

    assert_equal 0xff & ~0b1, @app.engine.voice_mute_mask
    @app.handle_key('s')

    assert_equal 0, @app.engine.voice_mute_mask
  end

  def test_vgm_seek_clears_the_previous_snapshot_before_the_worker_catches_up
    start_live_vgm_track
    use_screen(rows: 32, cols: 110)
    @app.handle_key('o')
    controller = @app.instance_variable_get(:@vgm_telemetry_controller)
    wait_for_live_vgm_rows(controller)
    channels = @app.instance_variable_get(:@vgm_live_view)
    previous_snapshot = channels.instance_variable_get(:@snapshot)

    refute_nil previous_snapshot

    @app.engine.seek(500)
    wait_until do
      @app.engine.vgm_telemetry_request&.revision != previous_snapshot.revision
    end
    @app.send(:tick_vgm_telemetry)

    assert_nil channels.snapshot
  end

  def test_vgm_telemetry_suspends_when_a_higher_modal_covers_now_playing
    start_live_vgm_track
    use_screen(rows: 32, cols: 110)
    @app.handle_key('o')
    controller = @app.instance_variable_get(:@vgm_telemetry_controller)
    wait_for_live_vgm_rows(controller)
    channels = @app.instance_variable_get(:@vgm_live_view)

    refute_nil channels.snapshot
    @app.instance_variable_set(:@config_error, 'configuration error')

    @app.send(:tick_vgm_telemetry)

    refute controller.instance_variable_get(:@visible)
    assert_nil channels.snapshot
  end

  def start_live_vgm_track
    library = @app.instance_variable_get(:@library)
    existing = library.all_tracks.first
    path = File.join(@music, 'live.vgm')
    File.binwrite(path, VgmBuilder.new(ym2612_clock: 7_670_454)
      .ym2612(0, 0x28, 0xf0).wait(500_000).end.bytes)
    id = library.upsert_track(folder_id: existing.folder_id, physical_path: path,
                              backend: 'gme', format: 'vgm', title: 'Live FM', artist: 'Chip')
    track = library.find_track(id)
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    @app.handle_events
  end

  def wait_for_live_vgm_rows(controller)
    wait_until(timeout: 3, interval: 0.01, failure_message: 'VGM channel snapshot was not rendered') do
      controller.tick
      @app.handle_events
      @app.render
      back_buffer_text.include?('FM 1')
    end
  end

  private

  def open_now_playing_on_two_gbs_tracks
    library = @app.instance_variable_get(:@library)
    tracks = library.all_tracks.select { |entry| entry.format == 'gbs' }.first(2)
    @app.engine.enqueue_now(tracks)
    wait_until { @app.engine.state[:track]&.id == tracks.first.id }
    @app.handle_events
    use_screen(rows: 40, cols: 110)
    @app.handle_key('o')
    tracks
  end
end
