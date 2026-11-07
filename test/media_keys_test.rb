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

  # Regression: a helper that crashed or was killed closed its stdin, and
  # the next update raised Errno::EPIPE on the UI thread, quitting the
  # player over an optional feature.
  def test_dead_helper_disables_media_keys_instead_of_raising
    pipe = BrokenPipe.new
    media_keys = RubyPlayer::MediaKeys.new(event_bus: RubyPlayer::EventBus.new, helper_launcher: -> { pipe })
    media_keys.start

    media_keys.update(playing_state)
    media_keys.update(playing_state(title: 'Another track'))

    assert_equal 1, pipe.write_attempts
    media_keys.stop
  end

  # Regression: JSON.generate raised on tags holding invalid UTF-8.
  def test_invalid_utf8_tags_are_replaced_before_sending
    pipe = RecordingPipe.new
    media_keys = RubyPlayer::MediaKeys.new(event_bus: RubyPlayer::EventBus.new, helper_launcher: -> { pipe })
    media_keys.start

    media_keys.update(playing_state(title: "Bad \xFF tag".b))

    assert_equal 'Bad � tag', JSON.parse(pipe.lines.last)['title']
  end

  private

  def playing_state(title: 'Test track')
    track = RubyPlayer::Track.new(title: title, artist: 'Test artist', duration_ms: 60_000)
    { track: track, playing: true, paused: false, position_ms: 1_000 }
  end

  # Stands in for the helper's stdin/stdout pipe.
  class RecordingPipe
    attr_reader :lines

    def initialize
      @lines = []
    end

    def each_line = nil
    def puts(line) = @lines << line
    def flush = nil
    def close_write = nil
    def close = nil
    def pid = nil
  end

  class BrokenPipe < RecordingPipe
    attr_reader :write_attempts

    def puts(_line)
      @write_attempts = (@write_attempts || 0) + 1
      raise Errno::EPIPE
    end
  end
end
