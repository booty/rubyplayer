# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'
require_relative 'support/rip_fixtures'

class AppHesLiveTest < Minitest::Test
  include TestSupport::AppTestSupport

  # Air Zonk with its playlist, scanned beside the shared library; playlist
  # track 1 is the 1:50 Opening.
  def setup
    super
    path = TestSupport::RipFixtures.path(:air_zonk)
    FileUtils.cp([path, path.sub(/\.hes\z/, '.m3u')], @music)
    @app.scan_paths([@music], wait: true)
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'hes' && entry.subtune_index == 1 }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    wait_until { @app.engine.chip_live_kind == :hes }
    @app.handle_events
    use_screen(rows: 50, cols: 160)
  end

  def test_hes_opens_on_a_full_width_live_page
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    text = wait_for_rows

    assert_includes text, 'HES LIVE'
    ['1 Wave 1', '4 Wave 4', '5 Multi 1', '6 Multi 2'].each { |label| assert_includes text, label }
    assert_includes text, 'HuC6280 PSG · 7.16 MHz'
  end

  def test_tab_switches_between_info_and_live_and_o_advances
    @app.handle_key('o')
    wait_for_rows
    @app.handle_key('tab')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    assert_includes rendered_text, 'Technical'
    @app.handle_key('tab')

    assert_includes wait_for_rows, 'HES LIVE'
    @app.handle_key('o')

    assert_equal :tracker, @app.instance_variable_get(:@now_playing_page)
    assert @app.show_now_playing
  end

  # Each PSG voice is its own libgme voice; a solo mutes the other five.
  def test_m_mutes_and_s_solos_the_selected_voice
    @app.handle_key('o')
    wait_for_rows
    @app.handle_key('down')
    @app.handle_key('m')

    assert_equal 0b10, @app.engine.voice_mute_mask
    assert_match(/2 Wave 2 .* M\b/, rendered_text)
    @app.handle_key('m')
    @app.handle_key('s')

    assert_equal 0b11_1101, @app.engine.voice_mute_mask
    @app.handle_key('s')

    assert_equal 0, @app.engine.voice_mute_mask
  end

  # A seek starts a new history generation: notes from before it go.
  def test_seeking_clears_old_history
    @app.handle_key('o')
    tracker = @app.instance_variable_get(:@chip_pages).fetch(:hes).tracker
    wait_until(timeout: 3, interval: 0.01, failure_message: 'no HES notes recorded') do
      rendered_text
      note_samples(tracker).any?
    end
    before = tracker.snapshot.revision
    seek_sample = tracker.now_sample
    @app.engine.seek(20_000)
    wait_until(timeout: 3, interval: 0.01, failure_message: 'seek did not reach the page') do
      rendered_text
      # Empty between the reset and the new generation's first record.
      revision = tracker.snapshot&.revision
      revision && revision != before
    end

    assert(note_samples(tracker).all? { |sample| sample >= seek_sample })
  end

  # The second `o` opens the Tracker; its clock is the track position, not
  # the output frames the HES tracker counts since launch.
  def test_o_opens_the_tracker_at_the_track_position_and_closes_after
    @app.handle_key('o')
    wait_for_rows
    @app.handle_key('o')

    assert_equal :tracker, @app.instance_variable_get(:@now_playing_page)
    text = nil
    wait_until(timeout: 3, interval: 0.01, failure_message: 'no HES tracker notes') do
      text = rendered_text
      text.match?(/\d:\d\d\.\d\d +.*[A-G][-#]\d/)
    end

    assert_includes text, 'HuC6280 PSG'
    assert_includes text, 'Wave 1'
    minutes, seconds = text[/HES TRACKER · (\d+:\d+\.\d+)/, 1].split(':').map(&:to_f)

    assert_in_delta @app.engine.state[:position_ms] / 1000.0, (minutes * 60) + seconds, 0.5
    @app.handle_key('o')

    refute @app.show_now_playing
  end

  def test_hes_live_page_does_not_start_vgm_telemetry
    @app.handle_key('o')
    @app.send(:tick_vgm_telemetry)

    refute @app.instance_variable_get(:@vgm_telemetry_controller).instance_variable_get(:@visible)
  end

  private

  def note_samples(tracker)
    snapshot = tracker.snapshot
    events = snapshot && snapshot.chips.first.details[:events]
    RubyPlayer::Vgm::NoteLog.decode(events).map(&:sample)
  end

  def rendered_text
    @app.handle_events
    @app.render
    back_buffer_text
  end

  # Snapshots reach the page once the device plays the first chunk.
  def wait_for_rows
    text = nil
    wait_until(timeout: 3, interval: 0.01, failure_message: 'HES voices were not rendered') do
      text = rendered_text
      text.include?('1 Wave 1')
    end
    text
  end
end
