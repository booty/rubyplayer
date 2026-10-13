# frozen_string_literal: true

require 'test_helper'
require_relative 'support/app_test_support'

class AppSpcLiveTest < Minitest::Test
  include TestSupport::AppTestSupport

  def setup
    super
    FileUtils.cp(File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc'), @music)
    @app.scan_paths([@music], wait: true)
    library = @app.instance_variable_get(:@library)
    track = library.all_tracks.find { |entry| entry.format == 'spc' }
    @app.engine.enqueue_now([track])
    wait_until { @app.engine.state[:track]&.id == track.id }
    wait_until { @app.engine.spc_live&.snapshot }
    @app.handle_events
    use_screen(rows: 50, cols: 160)
  end

  def test_spc_opens_on_a_full_width_live_page
    @app.handle_key('o')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    text = rendered_text

    assert_includes text, 'S-DSP LIVE'
    (0..7).each { |voice| assert_match(/^.{2,6}#{voice}  /, text) }
    heading = text.lines.find { |line| line.include?('ENVX') }

    assert_operator heading.index('State'), :>, 88, 'live page should use more than the info page width'
  end

  def test_second_o_closes_single_live_page
    @app.handle_key('o')
    @app.handle_key('o')

    refute @app.show_now_playing
  end

  def test_tab_switches_between_info_and_live
    @app.handle_key('o')
    @app.handle_key('tab')

    assert_equal :info, @app.instance_variable_get(:@now_playing_page)
    refute_includes rendered_text, 'S-DSP LIVE'
    assert_includes rendered_text, 'Technical'

    @app.handle_key('tab')

    assert_equal :live, @app.instance_variable_get(:@now_playing_page)
    assert_includes rendered_text, 'S-DSP LIVE'
  end

  def test_down_selects_the_next_voices_sample
    @app.handle_key('o')
    @app.handle_key('down')

    assert_includes rendered_text, 'voice 1'
  end

  def test_digit_keys_toggle_voice_mute_and_s_solos_the_selected_voice
    @app.handle_key('o')
    @app.handle_key('2')

    assert_equal 0b100, @app.engine.spc_live.mute_mask
    assert_match(/^.{2,6}2  .*M/, rendered_text)
    @app.handle_key('2')

    assert_equal 0, @app.engine.spc_live.mute_mask
    @app.handle_key('down')
    @app.handle_key('s')

    assert_equal 0xff & ~0b10, @app.engine.spc_live.mute_mask
    @app.handle_key('s')

    assert_equal 0, @app.engine.spc_live.mute_mask
  end

  def test_spc_live_page_does_not_start_vgm_telemetry
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
end
