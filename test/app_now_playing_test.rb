require 'test_helper'
require_relative 'support/app_test_support'

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
    wait_until do
      @app.handle_events
      @app.render
      back_buffer_text.include?('Chips: Game Boy APU')
    end

    assert_includes back_buffer_text, 'Voices: 2 pulse + 1 wave + 1 noise'
    assert_includes back_buffer_text, 'System:'
    refute_includes back_buffer_text, 'Bit rate:'
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
    assert_includes back_buffer_text, 'Technical'
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
end
