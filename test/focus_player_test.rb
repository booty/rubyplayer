require "test_helper"

class FocusPlayerTest < Minitest::Test
  class FragmentReader
    def initialize(chunks)
      @chunks = chunks
      @closed = false
    end

    def read_nonblock(_size, exception:)
      @chunks.empty? ? nil : @chunks.shift
    end

    def close = @closed = true
    def closed? = @closed
  end

  class FakeWriter
    def initialize = @closed = false
    def close = @closed = true
    def closed? = @closed
  end

  def build_player(spawn:, kill: ->(*) {}, waitpid: ->(*) { 1 },
                   clock: -> { 0.0 }, sleeper: ->(_) {}, pipe: IO.method(:pipe))
    RubyPlayer::FocusPlayer.new(spawn: spawn, kill: kill, waitpid: waitpid,
                                clock: clock, sleeper: sleeper, pipe: pipe)
  end

  def test_play_configures_sox_as_raw_pcm_source
    calls = []
    reader = FragmentReader.new([])
    writer = FakeWriter.new
    player = build_player(
      spawn: lambda do |*args, **opts|
        calls << [args, opts]
        42
      end,
      pipe: -> { [reader, writer] }
    )
    sound = RubyPlayer::FocusSounds::ALL.first

    assert player.play(sound, sample_rate: 48_000)

    expected = ["sox", "-q", "-n", "-t", "raw", "-e", "floating-point", "-b", "32",
                "-c", "2", "-r", "48000", "-", *sound.sox_args]
    assert_equal expected, calls.first[0]
    assert_equal File::NULL, calls.first[1][:in]
    assert_equal File::NULL, calls.first[1][:err]
    assert writer.closed?
    assert_predicate player, :playing?
  ensure
    player&.stop
  end

  def test_read_buffers_partial_pcm_frames
    frame = "\x00".b * RubyPlayer::AudioFormat::BYTES_PER_FRAME
    reader = FragmentReader.new([frame + "\x00".b, "\x00".b * 7])
    writer = FakeWriter.new
    player = build_player(spawn: ->(*, **) { 42 }, pipe: -> { [reader, writer] })
    player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)

    assert_equal frame, player.read(1)
    assert_equal frame, player.read(1)
  ensure
    player&.stop
  end

  def test_read_returns_empty_bytes_when_pipe_would_block
    reader = FragmentReader.new([:wait_readable])
    writer = FakeWriter.new
    player = build_player(spawn: ->(*, **) { 42 }, pipe: -> { [reader, writer] })
    player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)

    assert_equal "".b, player.read(1)
    assert_predicate player, :playing?
  ensure
    player&.stop
  end

  def test_eof_reaps_child_and_clears_state
    wait_calls = []
    reader = FragmentReader.new([])
    writer = FakeWriter.new
    player = build_player(
      spawn: ->(*, **) { 42 },
      waitpid: lambda do |*args|
        wait_calls << args
        42
      end,
      pipe: -> { [reader, writer] }
    )
    player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)

    assert_nil player.read(1)

    assert_includes wait_calls, [42, Process::WNOHANG]
    refute_predicate player, :playing?
    assert_nil player.current
  end

  def test_play_replaces_current_sound
    killed = []
    pids = [42, 43]
    player = build_player(spawn: ->(*, **) { pids.shift }, kill: ->(*args) { killed << args })

    player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)
    player.play(RubyPlayer::FocusSounds::ALL[1], sample_rate: 48_000)

    assert_includes killed, ["TERM", 42]
    assert_equal RubyPlayer::FocusSounds::ALL[1], player.current
  ensure
    player&.stop
  end

  def test_stop_kills_child_when_term_does_not_exit
    killed = []
    times = [0.0, 0.0, 1.1]
    player = build_player(
      spawn: ->(*, **) { 42 }, kill: ->(*args) { killed << args },
      waitpid: ->(*) { nil }, clock: -> { times.shift || 1.1 }
    )
    player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)

    assert player.stop
    assert_includes killed, ["TERM", 42]
    assert_includes killed, ["KILL", 42]
    refute_predicate player, :playing?
  end

  def test_stop_wraps_termination_errors_after_clearing_state
    player = build_player(
      spawn: ->(*, **) { 42 },
      kill: ->(*) { raise Errno::EPERM }
    )
    player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)

    error = assert_raises(RubyPlayer::FocusPlayer::Error) { player.stop }

    assert_instance_of Errno::EPERM, error.cause
    assert_match(/unable to stop sox/, error.message)
    refute_predicate player, :playing?
  end

  def test_play_reports_missing_sox
    player = build_player(spawn: ->(*, **) { raise Errno::ENOENT })

    error = assert_raises(RubyPlayer::FocusPlayer::Error) do
      player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)
    end
    assert_equal "sox executable not found", error.message
  end

  def test_play_closes_pipe_and_wraps_other_spawn_errors
    reader = FragmentReader.new([])
    writer = FakeWriter.new
    player = build_player(
      spawn: ->(*, **) { raise Errno::EACCES },
      pipe: -> { [reader, writer] }
    )

    error = assert_raises(RubyPlayer::FocusPlayer::Error) do
      player.play(RubyPlayer::FocusSounds::ALL.first, sample_rate: 48_000)
    end

    assert_instance_of Errno::EACCES, error.cause
    assert_match(/unable to start sox/, error.message)
    assert reader.closed?
    assert writer.closed?
  end
end
