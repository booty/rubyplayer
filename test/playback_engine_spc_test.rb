# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/audio_output'
require 'rubyplayer/playback_engine'
require 'rubyplayer/spc/snapshot'

# The engine must show the S-DSP state of the audio being heard, not of the
# chunk the decoder just produced (up to a ring buffer and a chunk ahead).
class PlaybackEngineSpcTest < Minitest::Test
  RATE = 48_000
  CAPACITY = 40_000

  # Mirrors the native ring: writes are accepted up to free space, and only
  # play! (the device callback) advances the played counter.
  class FakeRing
    attr_reader :sample_rate, :frames_played

    def initialize
      @sample_rate = RATE
      @frames_played = 0
      @buffered = 0
      @mutex = Mutex.new
    end

    def start; end
    def paused=(_value); end
    def flush = @mutex.synchronize { @buffered = 0 }
    def buffered_frames = @mutex.synchronize { @buffered }
    def writable_frames = @mutex.synchronize { CAPACITY - @buffered }

    def write(data)
      @mutex.synchronize do
        accepted = [data.bytesize / RubyPlayer::AudioFormat::BYTES_PER_FRAME, CAPACITY - @buffered].min
        @buffered += accepted
        accepted
      end
    end

    def play!(frames)
      @mutex.synchronize do
        frames = [frames, @buffered].min
        @buffered -= frames
        @frames_played += frames
      end
    end
  end

  # Each read's single snapshot (at the chunk's first frame) carries the read
  # number in regs[0]; RAM is a distinct string per read.
  class SnapshotHandle
    attr_reader :reads, :muted_on

    def initialize = @reads = 0

    def read(frames)
      @reads += 1
      ([0.0] * frames * 2).pack('e*')
    end

    def take_snapshots
      regs = Array.new(128, 0)
      regs[0] = @reads
      [[0, *regs, *Array.new(24, 0), 0].pack(RubyPlayer::Spc::Snapshot::FORMAT), 1]
    end

    def copy_ram = "ram #{@reads}".freeze
    def close; end

    def mute(mask) = @muted_on = [mask, Thread.current]
  end

  class PlainHandle
    def read(frames) = ([0.0] * frames * 2).pack('e*')
    def close; end
  end

  class Backend
    def initialize(handle_class) = @handle_class = handle_class
    def open(_path, _subtune, **) = @handle_class.new
  end

  class Registry
    def initialize(handle_class) = @backend = Backend.new(handle_class)
    def backend_for(_path) = @backend
  end

  class FakeLibrary
    def rating_of(_id) = nil
    def record_history(**); end
    # Keep this fake method named after the production library API.
    # rubocop:disable Naming/AccessorMethodName
    def set_errored(_id); end
    # rubocop:enable Naming/AccessorMethodName
  end

  class FakeFocus
    def stop; end
  end

  # Every test calls start, so the engine and bus always exist here.
  def teardown
    @engine.shutdown
    @bus.reader.close unless @bus.reader.closed?
    @bus.instance_variable_get(:@writer).close
  end

  def test_live_state_follows_the_played_frame
    start(SnapshotHandle)

    assert_equal 1, @engine.spc_live.snapshot.regs[0], 'first chunk is playing'

    @audio.play!(chunk_frames + 100)

    assert_equal 2, @engine.spc_live.snapshot.regs[0]
    assert_match(/\Aram \d+\z/, @engine.spc_live.ram)
  end

  # Mute is applied by the decoder thread, which owns the native handle, but
  # the requested mask is visible to the UI at once.
  def test_mute_mask_reaches_the_handle_on_the_decoder_thread
    start(SnapshotHandle)
    handle = @engine.instance_variable_get(:@handle)
    @engine.mute_spc_voices(0b100)

    assert_equal 0b100, @engine.spc_live.mute_mask
    wait_until { handle.muted_on }

    assert_equal 0b100, handle.muted_on.first
    refute_equal Thread.current, handle.muted_on.last
  end

  def test_a_new_track_starts_unmuted
    start(SnapshotHandle)
    first = @engine.instance_variable_get(:@handle)
    @engine.mute_spc_voices(0xff)
    wait_until { first.muted_on }
    @engine.enqueue_now([track])
    wait_until { !@engine.instance_variable_get(:@handle).equal?(first) && @engine.spc_live }

    assert_equal 0, @engine.spc_live.mute_mask
  end

  def test_no_live_state_for_handles_without_snapshots
    start(PlainHandle)

    assert_nil @engine.spc_live
  end

  def test_stopping_playback_clears_live_state
    start(SnapshotHandle)
    @engine.stop

    assert_nil @engine.spc_live
  end

  private

  def start(handle_class)
    @audio = FakeRing.new
    @bus = RubyPlayer::EventBus.new
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: Registry.new(handle_class), audio: @audio,
      library: FakeLibrary.new, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false),
      archive_cache: nil, focus_player: FakeFocus.new
    )
    @engine.start
    @engine.enqueue_now([track])
    wait_until { @audio.buffered_frames == CAPACITY }
  end

  def chunk_frames = RubyPlayer::DEFAULTS['audio']['decode_chunk_frames']

  def track
    RubyPlayer::Track.new(id: 1, folder_id: 1, physical_path: '/tmp/song.spc', archive_entry: '',
                          subtune_index: 0, backend: 'snes_spc', format: 'spc', title: 'Song',
                          duration_ms: nil)
  end
end
