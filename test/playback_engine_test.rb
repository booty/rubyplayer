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

  class FakeFocusSource
    attr_reader :played, :read_threads, :stop_calls

    def initialize
      @played = []
      @read_threads = []
      @stop_calls = 0
      @playing = false
    end

    def play(sound, sample_rate:)
      @played << [sound, sample_rate]
      @playing = true
    end

    def read(frames)
      return nil unless @playing

      @read_threads << Thread.current
      ([0.0] * frames * RubyPlayer::AudioFormat::CHANNELS).pack("e*")
    end

    def stop
      @stop_calls += 1
      @playing = false
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @folder = @lib.upsert_folder(parent_id: nil, name: "m", path: @tmp, kind: "dir")
    @bus = FakeBus.new
    @focus_source = FakeFocusSource.new
    @audio = RubyPlayer::AudioOutput.new(sample_rate: 44_100, ring_buffer_ms: 200,
                                         null_backend: true)
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: RubyPlayer::Backends::Registry.new,
      audio: @audio, library: @lib, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: "/nonexistent.rb", create_if_missing: false),
      archive_cache: RubyPlayer::ArchiveCache.new(root: File.join(@tmp, "cache")),
      focus_player: @focus_source
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
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until (r = yield)
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk "timed out waiting" if now > deadline
      sleep 0.02
    end
    r
  end

  def wait_for_event(type, timeout = 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      flunk "timed out waiting for #{type}" if now > deadline
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

  def test_stop_ends_playback_without_advancing_queue
    first = make_track("shantae.gbs")
    second = make_track("shantae.gbs", subtune: 1)
    @engine.enqueue_now([first, second])
    wait_for_event(:track_started)

    @engine.stop
    wait_for { !@engine.state[:playing] }

    assert_equal [first.id, second.id], @engine.queue_items.map(&:id)
    assert_nil @engine.state[:track]
  end

  def test_focus_pcm_is_pumped_by_decoder_thread_without_changing_queue
    queued = make_track("shantae.gbs")
    @engine.enqueue_end([queued])
    sound = RubyPlayer::FocusSounds::ALL.first

    @engine.play_focus(sound)
    wait_for { @focus_source.read_threads.any? }

    assert_equal [[sound, 44_100]], @focus_source.played
    assert @focus_source.read_threads.all? { |thread| thread.name == "decoder" }
    assert_equal [queued.id], @engine.queue_items.map(&:id)
  ensure
    @engine.stop_focus
  end

  def test_state_exposes_focus_sound_and_queued_track
    queued = make_track("shantae.gbs")
    @engine.enqueue_end([queued])
    sound = RubyPlayer::FocusSounds::ALL.first

    @engine.play_focus(sound)
    state = @engine.state

    assert_equal sound, state[:focus_sound]
    assert_equal queued.id, state[:next_track].id
    assert_nil state[:track]
  ensure
    @engine.stop_focus
  end

  def test_state_exposes_track_after_current_as_next
    first = make_track("shantae.gbs")
    second = make_track("shantae.gbs", subtune: 1)
    @engine.enqueue_now([first, second])
    wait_for_event(:track_started)

    state = @engine.state

    assert_nil state[:focus_sound]
    assert_equal second.id, state[:next_track].id
  end

  def test_state_exposes_queue_head_as_next_while_stopped
    queued = make_track("shantae.gbs")
    @engine.enqueue_end([queued])

    state = @engine.state

    assert_nil state[:focus_sound]
    assert_equal queued.id, state[:next_track].id
  end

  def test_plays_track_stored_inside_an_archive
    zip = File.join(FIXTURES, "musha.zip")
    id = @lib.upsert_track(folder_id: @folder, physical_path: zip,
                           archive_entry: "10 - Round Clear.vgm",
                           backend: "gme", format: "vgm",
                           title: "Round Clear", duration_ms: 2_000)
    track = @lib.find_track(id)
    @engine.enqueue_now([track])
    wait_for { @engine.state[:playing] }
    assert_equal id, @engine.state[:track]&.id
    # must NOT be flagged errored (i.e. the engine resolved the entry to a
    # real extracted file instead of handing the .zip to a backend)
    assert_equal 0, @lib.find_track(id).errored
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

  def test_remove_track_ids_removes_a_queued_track_that_is_not_playing
    t1 = make_track("shantae.gbs", subtune: 7)
    t2 = make_track("shantae.gbs", subtune: 8)
    @engine.enqueue_now([t1, t2])
    wait_for_event(:track_started)

    @engine.remove_track_ids([t2.id])

    wait_for { @engine.queue_items.map(&:id) == [t1.id] }
  end

  # Removing the currently-playing track can't just yank it out of the queue
  # array -- the decoder thread has an open handle on it. This must route
  # through :skip (like #remove_at's index-0 case) so finish_and_advance
  # closes the handle and moves on cleanly.
  def test_remove_track_ids_skips_past_the_currently_playing_track
    t1 = make_track("shantae.gbs", subtune: 9, duration_ms: 60_000)
    t2 = make_track("shantae.gbs", subtune: 10)
    @engine.enqueue_now([t1, t2])
    ev = wait_for_event(:track_started)
    assert_equal t1.id, ev[1][:track].id

    @engine.remove_track_ids([t1.id])

    ev = wait_for_event(:track_started)
    assert_equal t2.id, ev[1][:track].id
    refute_includes @engine.queue_items.map(&:id), t1.id
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

  # The UI shows position as m:ss, so :position events finer than one
  # displayed second are pure wake-up noise — each one writes the EventBus
  # self-pipe and rouses the main loop's IO.select. Before the throttle,
  # pump published once per decoded chunk (~10/s at 4096 frames), which
  # defeated the idle loop's attempt to sleep between meaningful changes.
  def test_position_publishes_at_most_once_per_displayed_second
    t = make_track("shantae.gbs", duration_ms: 60_000)
    @engine.enqueue_now([t])
    wait_for_event(:track_started)
    wait_for { @engine.state[:position_ms] > 500 }
    @engine.shutdown

    seconds = @bus.all.filter_map { |type, payload| payload[:position_ms] / 1000 if type == :position }
    refute_empty seconds
    assert_equal seconds.uniq, seconds,
                 "expected one :position event per displayed second, got #{seconds.inspect}"
  end
end
