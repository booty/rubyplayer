# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

class AppNsfLiveTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    FileUtils.cp(File.join(FIXTURES, 'nsf', 'castlevania-3-japan.nsf'), @music)
    @app.scan_paths([@music], wait: true)
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'nsf' && entry.subtune_index.zero? }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    wait_until { @app.engine.chip_live_kind == :nsf }
    @app.handle_events
    use_screen(rows: 50, cols: 160)
  end

  def test_nsf_opens_on_a_full_width_live_page
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    text = wait_for_rows

    assert_includes text, 'NSF LIVE'
    ['1 Pulse 1', '5 DMC', '6 VRC6 Pulse 1', '8 VRC6 Saw'].each { |label| assert_includes text, label }
    assert_includes text, 'Konami VRC6 · 1.79 MHz'
  end

  # Channels mute by libgme voice: the VRC6 saw is voice 5 though listed last.
  def test_m_mutes_and_s_solos_the_selected_channel
    @app.handle_key('o')
    wait_for_rows
    7.times { @app.handle_key('down') }
    @app.handle_key('m')

    assert_equal 1 << 5, @app.engine.voice_mute_mask
    @app.handle_key('m')
    @app.handle_key('s')

    assert_equal 0xff & ~(1 << 5), @app.engine.voice_mute_mask
  end

  def test_nsf_live_page_does_not_start_vgm_telemetry
    @app.handle_key('o')
    @app.send(:tick_vgm_telemetry)

    refute @app.instance_variable_get(:@vgm_telemetry_controller).instance_variable_get(:@visible)
  end

  private

  def rendered_text
    @app.handle_events
    @app.render
    back_buffer_text
  end

  # Snapshots reach the page once the device plays the first chunk.
  def wait_for_rows
    text = nil
    wait_until(timeout: 3, interval: 0.01, failure_message: 'NSF channels were not rendered') do
      text = rendered_text
      text.include?('1 Pulse 1')
    end
    text
  end
end
