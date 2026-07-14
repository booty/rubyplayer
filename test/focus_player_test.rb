require "test_helper"

class FocusPlayerTest < Minitest::Test
  class FakeAudio
    BYTES_PER_FRAME = 8

    attr_reader :writes, :pause_values, :flushes

    def initialize(sample_rate: 48_000)
      @sample_rate = sample_rate
      @writes = []
      @pause_values = []
      @flushes = 0
    end

    attr_reader :sample_rate

    def write(bytes)
      @writes << bytes
      bytes.bytesize / BYTES_PER_FRAME
    end

    def paused=(value)
      @pause_values << value
    end
    def flush = @flushes += 1
  end

  class BlockingAudio < FakeAudio
    def initialize
      super
      @write_started = Queue.new
      @release_write = Queue.new
    end

    def write(bytes)
      @write_started << true
      @release_write.pop
      super
    end

    def wait_for_write = @write_started.pop
    def release = @release_write << true
  end

  class FragmentReader
    def initialize(chunks)
      @chunks = chunks
      @closed = false
    end

    def readpartial(_size)
      raise EOFError if @chunks.empty?

      @chunks.shift
    end

    def close = @closed = true
    def closed? = @closed
  end

  class FakeWriter
    def initialize = @closed = false
    def close = @closed = true
    def closed? = @closed
  end

  def setup
    @audio = FakeAudio.new
  end

  def build_player(spawn:, kill: ->(*) {}, waitpid: ->(*) { 1 },
                   clock: -> { 0.0 }, sleeper: ->(_) {}, pipe: IO.method(:pipe))
    RubyPlayer::FocusPlayer.new(audio: @audio, spawn: spawn, kill: kill, waitpid: waitpid,
                                clock: clock, sleeper: sleeper, pipe: pipe)
  end

  def wait_until(timeout: 1)
    deadline = Time.now + timeout
    until yield
      flunk "timed out waiting for condition" if Time.now > deadline
      sleep 0.01
    end
  end

  def test_play_sends_quiet_sox_pcm_to_app_audio
    calls = []
    sample = "\x00".b * FakeAudio::BYTES_PER_FRAME
    player = build_player(spawn: lambda do |*args, **opts|
      calls << [args, opts]
      opts[:out].write(sample)
      42
    end)
    sound = RubyPlayer::FocusSounds::ALL.first

    assert player.play(sound)
    wait_until { @audio.writes == [sample] }

    expected = ["sox", "-q", "-n", "-t", "raw", "-e", "floating-point", "-b", "32",
                "-c", "2", "-r", "48000", "-", *sound.sox_args.drop(1)]
    assert_equal expected, calls.first[0]
    assert_equal File::NULL, calls.first[1][:in]
    assert_equal File::NULL, calls.first[1][:err]
    refute calls.first[1].key?(:pgroup)
    assert_equal false, @audio.pause_values.first
  ensure
    player&.stop
  end

  def test_stop_pauses_and_flushes_app_audio
    killed = []
    player = build_player(spawn: ->(*, **) { 42 }, kill: ->(*args) { killed << args })
    player.play(RubyPlayer::FocusSounds::ALL.first)

    assert player.stop
    assert_includes killed, ["TERM", 42]
    assert_equal [false, true], @audio.pause_values
    assert_equal 1, @audio.flushes
  end

  def test_pcm_pipe_buffers_partial_frames_before_writing_audio
    frame = "\x00".b * FakeAudio::BYTES_PER_FRAME
    reader = FragmentReader.new([frame + "\x00".b, "\x00".b * 7])
    writer = FakeWriter.new
    player = build_player(spawn: ->(*, **) { 42 }, pipe: -> { [reader, writer] })

    player.play(RubyPlayer::FocusSounds::ALL.first)
    wait_until { reader.closed? }

    assert_equal [frame, frame], @audio.writes
  ensure
    player&.stop
  end

  def test_stop_waits_for_prior_pcm_writer_before_replacement
    @audio = BlockingAudio.new
    sample = "\x00".b * FakeAudio::BYTES_PER_FRAME
    player = build_player(spawn: ->(*, **opts) { opts[:out].write(sample); 42 })
    player.play(RubyPlayer::FocusSounds::ALL.first)
    @audio.wait_for_write

    stopping = Thread.new { player.stop }
    assert_nil stopping.join(1.1), "stop returned while previous PCM writer was active"

    @audio.release
    assert stopping.join(1)
  ensure
    @audio&.release if stopping&.alive?
    stopping&.join
  end

  def test_stop_waits_for_pcm_writer_when_termination_raises
    @audio = BlockingAudio.new
    sample = "\x00".b * FakeAudio::BYTES_PER_FRAME
    player = build_player(
      spawn: ->(*, **opts) { opts[:out].write(sample); 42 },
      kill: ->(*) { raise Errno::EPERM }
    )
    player.play(RubyPlayer::FocusSounds::ALL.first)
    @audio.wait_for_write
    errors = Queue.new

    stopping = Thread.new do
      player.stop
    rescue StandardError => e
      errors << e
    end
    assert_nil stopping.join(0.1), "stop abandoned an active PCM writer after termination failed"

    @audio.release
    assert stopping.join(1)
    error = errors.pop
    assert_instance_of RubyPlayer::FocusPlayer::Error, error
    assert_instance_of Errno::EPERM, error.cause
    assert_match(/unable to stop sox/, error.message)
    refute_predicate player, :playing?
    assert_equal [false, true], @audio.pause_values
    assert_equal 1, @audio.flushes
  ensure
    @audio&.release if stopping&.alive?
    stopping&.join
  end

  def test_play_replaces_current_sound
    killed = []
    pids = [42, 43]
    player = build_player(spawn: ->(*, **) { pids.shift }, kill: ->(*args) { killed << args })

    player.play(RubyPlayer::FocusSounds::ALL.first)
    player.play(RubyPlayer::FocusSounds::ALL[1])

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
    player.play(RubyPlayer::FocusSounds::ALL.first)

    assert player.stop
    assert_includes killed, ["TERM", 42]
    assert_includes killed, ["KILL", 42]
    refute_predicate player, :playing?
    assert_nil player.current
  end

  def test_play_reports_missing_sox
    player = build_player(spawn: ->(*, **) { raise Errno::ENOENT })

    error = assert_raises(RubyPlayer::FocusPlayer::Error) do
      player.play(RubyPlayer::FocusSounds::ALL.first)
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
      player.play(RubyPlayer::FocusSounds::ALL.first)
    end

    assert_instance_of Errno::EACCES, error.cause
    assert_match(/unable to start sox/, error.message)
    assert reader.closed?
    assert writer.closed?
  end

  def test_unexpected_sox_exit_is_reaped_and_clears_playing_state
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

    player.play(RubyPlayer::FocusSounds::ALL.first)
    wait_until { !player.playing? }

    assert_includes wait_calls, [42, Process::WNOHANG]
    assert_nil player.current
    assert_equal [false, true], @audio.pause_values
    assert_equal 1, @audio.flushes
  end
end
