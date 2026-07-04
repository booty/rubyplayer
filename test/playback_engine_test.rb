require "test_helper"
require "tmpdir"
require "fileutils"
require "rubyplayer/audio_output"
require "rubyplayer/playback_engine"

class PlaybackEngineTest < Minitest::Test
  FakeBus = Class.new do
    attr_reader :events
    def initialize = @events = Queue.new
    def publish(type, **payload) = @events << [type, payload]
    def all = Array.new(@events.size) { @events.pop }
  end

  # A handle that opens fine (so open_and_play's own rescue never fires) but
  # raises on the first read -- reproduces gme_play failing on a
  # corrupt-but-openable file without needing a real corrupt fixture.
  class BoomHandle
    def read(_frames) = raise "decode boom: read after open"
    def seek(_ms) = false
    def close; end
  end

  class BoomBackend
    def open(_path, _subtune, sample_rate:) = BoomHandle.new
  end

  # Delegates to a real registry for every path except one trapped path,
  # which always resolves to BoomBackend. Lets a single test mix one
  # deliberately-broken track with real, playable fixtures.
  class TrapRegistry
    def initialize(fallback, trap_path, trap_backend)
      @fallback = fallback
      @trap_path = trap_path
      @trap_backend = trap_backend
    end

    def backend_for(path)
      path == @trap_path ? @trap_backend : @fallback.backend_for(path)
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @folder = @lib.upsert_folder(parent_id: nil, name: "m", path: @tmp, kind: "dir")
    @bus = FakeBus.new
    @audio = RubyPlayer::AudioOutput.new(sample_rate: 44_100, ring_buffer_ms: 200,
                                         null_backend: true)
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: RubyPlayer::Backends::Registry.new,
      audio: @audio, library: @lib, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: "/nonexistent.toml")
    )
    @engine.start
  end

  def teardown
    @engine.shutdown
    @audio.close
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  # Claim a tiny duration so the 5% history rule is crossed within ~0.1s of play.
  def make_track(fixture, duration_ms: 2_000, subtune: 0)
    path = File.join(FIXTURES, fixture)
    id = @lib.upsert_track(folder_id: @folder, physical_path: path,
                           subtune_index: subtune, backend: "gme", format: "gbs",
                           title: fixture, duration_ms: duration_ms)
    @lib.find_track(id)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    until (r = yield)
      flunk "timed out waiting" if Time.now > deadline
      sleep 0.02
    end
    r
  end

  def wait_for_event(type, timeout = 5)
    deadline = Time.now + timeout
    loop do
      flunk "timed out waiting for #{type}" if Time.now > deadline
      begin
        ev = @bus.events.pop(true)
        return ev if ev[0] == type
      rescue ThreadError
        sleep 0.02
      end
    end
  end

  def test_play_pause_skip_lifecycle
    t1 = make_track("shantae.gbs")
    t2 = make_track("shantae.gbs", subtune: 1)
    @engine.enqueue_now([t1, t2])
    ev = wait_for_event(:track_started)
    assert_equal t1.id, ev[1][:track].id
    wait_for { @engine.state[:position_ms].positive? }

    @engine.toggle_play # pause
    wait_for { @engine.state[:paused] }
    @engine.toggle_play # resume
    wait_for { !@engine.state[:paused] }

    @engine.skip
    ev = wait_for_event(:track_started)
    assert_equal t2.id, ev[1][:track].id

    @engine.skip # queue empty -> stops
    wait_for { !@engine.state[:playing] }
    assert_nil @engine.state[:track]
  end

  def test_history_recorded_after_5_percent
    t = make_track("shantae.gbs", duration_ms: 1_000) # 5% = 50ms
    @engine.enqueue_now([t])
    wait_for_event(:track_started)
    wait_for { @engine.state[:position_ms] > 100 }
    @engine.skip
    wait_for { @lib.history(limit: 5).size == 1 }
    assert_equal t.id, @lib.history(limit: 5).first[:track].id
  end

  def test_no_history_below_5_percent
    t = make_track("shantae.gbs", duration_ms: 3_600_000) # 5% = 3 minutes
    @engine.enqueue_now([t])
    wait_for_event(:track_started)
    @engine.skip
    sleep 0.2
    assert_empty @lib.history(limit: 5)
  end

  def test_skip_disliked_tracks
    t1 = make_track("shantae.gbs", subtune: 2)
    hated = make_track("shantae.gbs", subtune: 3)
    t3 = make_track("shantae.gbs", subtune: 4)
    @lib.set_rating(hated.id, 1)
    assert @engine.toggle_skip_disliked
    @engine.enqueue_now([t1, hated, t3])
    wait_for_event(:track_started)
    @engine.skip
    ev = wait_for_event(:track_started) # hated is skipped -> t3 starts
    assert_equal t3.id, ev[1][:track].id
  end

  def test_errored_track_is_flagged_and_skipped
    bad_path = File.join(@tmp, "bad.mod")
    File.write(bad_path, "junk")
    id = @lib.upsert_track(folder_id: @folder, physical_path: bad_path,
                           backend: "openmpt", format: "mod", title: "bad")
    good = make_track("shantae.gbs", subtune: 5)
    @engine.enqueue_now([@lib.find_track(id), good])
    ev = wait_for_event(:track_error)
    assert_equal id, ev[1][:track].id
    ev = wait_for_event(:track_started) # engine moved on
    assert_equal good.id, ev[1][:track].id
    assert_equal 1, @lib.find_track(id).errored
  end

  def test_decoder_survives_mid_decode_read_failure
    boom_path = File.join(@tmp, "boom.gbs")
    FileUtils.cp(File.join(FIXTURES, "shantae.gbs"), boom_path)
    boom_id = @lib.upsert_track(folder_id: @folder, physical_path: boom_path,
                                backend: "gme", format: "gbs", title: "boom")
    good = make_track("shantae.gbs", subtune: 6)

    # Swap in a registry that traps boom_path to a backend which opens fine
    # but raises on read, i.e. the failure mode this fix targets (open
    # succeeds, gme_play/read blows up mid-decode).
    real_registry = @engine.instance_variable_get(:@registry)
    @engine.instance_variable_set(
      :@registry, TrapRegistry.new(real_registry, boom_path, BoomBackend.new)
    )

    @engine.enqueue_now([@lib.find_track(boom_id), good])
    ev = wait_for_event(:track_error)
    assert_equal boom_id, ev[1][:track].id
    assert_equal 1, @lib.find_track(boom_id).errored

    # The decoder thread must still be alive to start the next track --
    # before this fix, the unhandled read error killed it and this would
    # time out.
    ev = wait_for_event(:track_started)
    assert_equal good.id, ev[1][:track].id
  end
end
