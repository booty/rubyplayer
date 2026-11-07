# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

class AppGbsLiveTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    library = @app.library
    track = library.all_tracks.find { |entry| entry.format == 'gbs' && entry.subtune_index == 1 }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    wait_until { @app.engine.chip_live_kind == :gbs }
    @app.handle_events
    use_screen(rows: 50, cols: 160)
  end

  def test_gbs_opens_on_a_full_width_live_page
    @app.handle_key('o')

    assert_equal :live, @app.now_playing_page
    # A chip live page is not VGM: it must leave the telemetry worker asleep.
    @app.send(:tick_vgm_telemetry)

    refute_predicate @app.vgm_telemetry_controller, :visible?
    text = wait_for_rows

    assert_includes text, 'GBS LIVE'
    ['1 Square 1', '2 Square 2', '3 Wave', '4 Noise'].each { |label| assert_includes text, label }
    assert_includes text, 'Game Boy APU · 4.19 MHz'
  end

  def test_tab_switches_between_info_and_live
    @app.handle_key('o')
    wait_for_rows
    @app.handle_key('tab')

    assert_equal :info, @app.now_playing_page
    assert_includes rendered_text, 'Technical'
    @app.handle_key('tab')

    assert_includes wait_for_rows, 'GBS LIVE'
  end

  def test_second_o_closes_single_live_page
    @app.handle_key('o')
    @app.handle_key('o')

    refute_predicate @app, :show_now_playing?
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

  private

  def wait_for_rows = wait_for_live_rows('1 Square 1')
end
