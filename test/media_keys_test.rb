require 'test_helper'
require 'rubyplayer/media_keys'

class MediaKeysTest < Minitest::Test
  def test_native_helper_has_an_app_identity
    helper = File.expand_path('../lib/rubyplayer/native/RubyPlayerMedia.app/Contents/MacOS/RubyPlayerMedia', __dir__)

    assert_equal 'com.booty.rubyplayer.media', IO.popen([helper, '--probe'], &:read).strip
  end

  def test_helper_accepts_playback_updates_and_stops
    media_keys = RubyPlayer::MediaKeys.new(event_bus: RubyPlayer::EventBus.new)
    track = RubyPlayer::Track.new(title: 'Test track', artist: 'Test artist', duration_ms: 60_000)
    media_keys.start

    media_keys.update(track: track, playing: true, paused: false, position_ms: 1_000)

    assert Process.kill(0, media_keys.instance_variable_get(:@io).pid)
  ensure
    media_keys&.stop
  end
end
