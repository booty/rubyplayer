require 'test_helper'
require_relative 'support/app_test_support'

class AppMediaKeysTest < Minitest::Test
  include TestSupport::AppTestSupport

  def test_remote_commands_follow_existing_playback_actions
    start_normal_playback
    bus = @app.instance_variable_get(:@bus)
    bus.publish(:media_command, action: :toggle_play)
    @app.handle_events
    wait_until(timeout: 2, interval: 0.01, failure_message: 'pause command was lost') do
      @app.engine.state[:paused]
    end

    assert @app.engine.state[:paused]

    bus.publish(:media_command, action: :play)
    @app.handle_events
    wait_until(timeout: 2, interval: 0.01, failure_message: 'play command was lost') do
      @app.engine.state[:playing] && !@app.engine.state[:paused]
    end

    refute @app.engine.state[:paused]

    first_id = @app.engine.state[:track].id
    bus.publish(:media_command, action: :next_track)
    @app.handle_events
    wait_until(timeout: 2, interval: 0.01, failure_message: 'next command was lost') do
      @app.engine.state[:track]&.id != first_id
    end

    refute_equal first_id, @app.engine.state[:track]&.id
  end

  def test_events_publish_playback_state_and_shutdown_stops_helper
    start_normal_playback
    @app.handle_events

    assert_equal @app.engine.state[:track], @media_keys.states.last[:track]

    @app.shutdown
    @app = nil

    assert_equal 1, @media_keys.stop_calls
  end
end
