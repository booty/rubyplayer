require 'test_helper'
require 'rubyplayer/playback_state'

class PlaybackStateTest < Minitest::Test
  def test_only_unpaused_playback_is_active
    assert RubyPlayer::PlaybackState.actively_playing?(playing: true, paused: false)
    refute RubyPlayer::PlaybackState.actively_playing?(playing: true, paused: true)
    refute RubyPlayer::PlaybackState.actively_playing?(playing: false, paused: false)
  end
end
