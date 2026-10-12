# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

class AppGbsLiveTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'gbs' && entry.subtune_index == 1 }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    wait_until { @app.engine.chip_live_kind == :gbs }
    @app.handle_events
    use_screen(rows: 50, cols: 160)
  end

  def test_gbs_opens_on_a_full_width_live_page
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    text = wait_for_rows

    assert_includes text, 'GBS LIVE'
    ['1 Square 1', '2 Square 2', '3 Wave', '4 Noise'].each { |label| assert_includes text, label }
    assert_includes text, 'Game Boy APU · 4.19 MHz'
  end

  def test_tab_switches_between_info_and_live
    @app.handle_key('o')
    wait_for_rows
    @app.handle_key('tab')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    assert_includes rendered_text, 'Technical'
    @app.handle_key('tab')

    assert_includes wait_for_rows, 'GBS LIVE'
  end

  # Each Game Boy channel is its own libgme voice.
  def test_m_mutes_and_s_solos_the_selected_channel
    @app.handle_key('o')
    wait_for_rows
    @app.handle_key('down')
    @app.handle_key('m')

    assert_equal 0b10, @app.engine.voice_mute_mask
    assert_match(/2 Square 2 .* M\b/, rendered_text)
    @app.handle_key('m')

    assert_equal 0, @app.engine.voice_mute_mask
    @app.handle_key('s')

    assert_equal 0b1101, @app.engine.voice_mute_mask
    @app.handle_key('s')

    assert_equal 0, @app.engine.voice_mute_mask
  end

  def test_gbs_live_page_does_not_start_vgm_telemetry
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
    wait_until(timeout: 3, interval: 0.01, failure_message: 'GBS channels were not rendered') do
      text = rendered_text
      text.include?('1 Square 1')
    end
    text
  end
end
