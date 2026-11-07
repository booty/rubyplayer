require 'test_helper'
require_relative 'support/app_test_support'

class AppEffectsTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_effect_panel_stacks_controls_and_keeps_session_settings
    use_screen(rows: 24, cols: 80)
    @app.handle_key('d')
    @app.render

    assert_includes back_buffer_text, 'Effects'
    assert_includes back_buffer_text, 'AM Radio'

    @app.handle_key('enter')
    @app.handle_key('right')
    @app.handle_key('down')
    @app.handle_key('enter')
    @app.handle_key('b')
    @app.render

    assert_includes back_buffer_text, 'BYPASS'
    rack = @app.instance_variable_get(:@effects_rack)

    assert_equal [true, 55], [rack.effects[0].enabled, rack.effects[0].intensity_percent]
    assert rack.effects[1].enabled
    assert_predicate rack, :bypassed?
    @app.handle_key('escape')
    @app.handle_key('d')

    assert rack.effects[0].enabled
    assert_predicate rack, :bypassed?
  end

  def test_short_panel_scrolls_to_last_effect
    use_screen(rows: 10, cols: 45)
    @app.handle_key('d')
    7.times { @app.handle_key('down') }
    @app.render

    assert_includes back_buffer_text, 'Echo Chamber'
    @app.handle_key('enter')

    assert @app.instance_variable_get(:@effects_rack).effects[7].enabled
    @app.handle_key('escape')

    refute @app.instance_variable_get(:@effects_modal)
  end

  def test_effect_shortcuts_are_case_insensitive
    @app.handle_key('D')
    @app.handle_key('B')

    assert_predicate @app.instance_variable_get(:@effects_rack), :bypassed?
    @app.handle_key('D')

    refute @app.instance_variable_get(:@effects_modal)
  end

  def test_effects_survive_switching_between_music_and_focus
    start_normal_playback
    audio = @app.instance_variable_get(:@audio)
    original_flush = audio.method(:flush)
    flush_count = 0
    audio.define_singleton_method(:flush) do
      flush_count += 1
      original_flush.call
    end
    @app.handle_key('d')
    @app.handle_key('enter')
    @app.handle_key('down')
    @app.handle_key('enter')
    @app.handle_key('escape')
    rack = @app.instance_variable_get(:@effects_rack)

    @app.engine.play_focus(RubyPlayer::FocusSounds::ALL.first)

    assert @app.engine.state[:focus_sound]
    assert rack.effects.first(2).all?(&:enabled)
    assert_operator flush_count, :>, 0

    prior_flush_count = flush_count
    @app.engine.stop_focus
    @app.engine.enqueue_now([@app.instance_variable_get(:@library).all_tracks.first])
    wait_until { @app.engine.state[:playing] && !@app.engine.state[:focus_sound] }

    assert rack.effects.first(2).all?(&:enabled)
    assert_operator flush_count, :>, prior_flush_count
  end

  def test_panel_keeps_playback_controls_and_returns_to_now_playing
    start_normal_playback
    @app.handle_key('o')
    @app.handle_key('d')

    assert @app.instance_variable_get(:@effects_modal)
    @app.handle_key('space')
    wait_until { @app.engine.state[:paused] }
    @app.handle_key('escape')

    assert @app.show_now_playing
  end

  def test_panel_honors_remapped_playback_key
    start_normal_playback
    @app.instance_variable_set(:@keymap, RubyPlayer::Keymap.new('global' => { 'j' => 'toggle_play' }))
    @app.handle_key('d')
    @app.handle_key('j')
    wait_until { @app.engine.state[:paused] }

    assert @app.instance_variable_get(:@effects_modal)
  end
end
