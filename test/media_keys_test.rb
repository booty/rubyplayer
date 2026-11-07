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

  # Regression: position_s changed every frame, so the unchanged-payload
  # check never matched and the helper got ~30 JSON lines a second while
  # animating. macOS extrapolates elapsed time from the playback rate, so
  # steady playback needs no position updates.
  def test_steady_playback_sends_no_position_updates
    pipe = RecordingPipe.new
    now_s = 100.0
    media_keys = RubyPlayer::MediaKeys.new(event_bus: RubyPlayer::EventBus.new, helper_launcher: -> { pipe },
                                           clock: -> { now_s })
    media_keys.start

    media_keys.update(playing_state(position_ms: 1_000))
    now_s += 0.5
    media_keys.update(playing_state(position_ms: 1_500))
    now_s += 0.5
    media_keys.update(playing_state(position_ms: 2_000))

    assert_equal 1, pipe.lines.size
  end

  def test_seek_and_pause_resend_position
    pipe = RecordingPipe.new
    now_s = 100.0
    media_keys = RubyPlayer::MediaKeys.new(event_bus: RubyPlayer::EventBus.new, helper_launcher: -> { pipe },
                                           clock: -> { now_s })
    media_keys.start

    media_keys.update(playing_state(position_ms: 1_000))
    now_s += 0.1
    media_keys.update(playing_state(position_ms: 30_000))
    now_s += 0.1
    media_keys.update(playing_state(position_ms: 30_100).merge(paused: true))

    assert_equal [1.0, 30.0, 30.1], pipe.lines.map { |line| JSON.parse(line)['position_s'] }
  end

  def test_helper_commands_are_published_by_name
    bus = RubyPlayer::EventBus.new
    pipe = RecordingPipe.new(incoming: %W[next_track\n unknown\n pause\n])
    media_keys = RubyPlayer::MediaKeys.new(event_bus: bus, helper_launcher: -> { pipe })
    media_keys.start
    media_keys.stop

    assert_equal [[:media_command, { action: :next_track }], [:media_command, { action: :pause }]], bus.drain
  end

  def test_playback_state_is_sent_by_name
    pipe = RecordingPipe.new
    media_keys = RubyPlayer::MediaKeys.new(event_bus: RubyPlayer::EventBus.new, helper_launcher: -> { pipe })
    media_keys.start

    media_keys.update(playing_state)
    media_keys.update(playing_state.merge(paused: true))
    media_keys.update(playing_state.merge(playing: false))

    assert_equal %w[playing paused stopped], pipe.lines.map { |line| JSON.parse(line)['state'] }
  end

  private

  def playing_state(title: 'Test track', position_ms: 1_000)
    track = RubyPlayer::Track.new(title: title, artist: 'Test artist', duration_ms: 60_000)
    { track: track, playing: true, paused: false, position_ms: position_ms }
  end

  # Stands in for the helper's stdin/stdout pipe.
  class RecordingPipe
    attr_reader :lines

    def initialize(incoming: [])
      @lines = []
      @incoming = incoming
    end

    def each_line(&) = @incoming.each(&)
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
