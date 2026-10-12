# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/audio_output'
require 'rubyplayer/playback_engine'

# Decoder-to-ring handoff: EQ levels follow the played frame, and a full ring
# is refilled in bursts instead of being polled with small writes.
class PlaybackEngineLevelsTest < Minitest::Test
  RATE = 48_000
  CAPACITY = 40_000

  # Mirrors the native ring: writes are accepted up to free space, and only
  # play! (the device callback) advances the played counter.
  class FakeRing
    attr_reader :sample_rate, :frames_played, :writes

    def initialize
      @sample_rate = RATE
      @frames_played = 0
      @buffered = 0
      @writes = 0
      @mutex = Mutex.new
    end

    def start; end
    def paused=(_value); end
    def flush = @mutex.synchronize { @buffered = 0 }
    def buffered_frames = @mutex.synchronize { @buffered }
    def writable_frames = @mutex.synchronize { CAPACITY - @buffered }

    def write(data)
      @mutex.synchronize do
        @writes += 1
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

  # First read is a low tone, every later read a high tone.
  class ToneHandle
    def initialize = @reads = 0

    def read(frames)
      frequency = (@reads += 1) == 1 ? 80 : 8_000
      Array.new(frames) do |i|
        value = 0.8 * Math.sin(2 * Math::PI * frequency * i / RATE.to_f)
        [value, value]
      end.flatten.pack('e*')
    end

    def close; end
  end

  class Backend
    def open(_path, _subtune, **) = ToneHandle.new
  end

  class Registry
    def backend_for(_path) = Backend.new
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

  def setup
    @audio = FakeRing.new
    @bus = RubyPlayer::EventBus.new
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: Registry.new, audio: @audio,
      library: FakeLibrary.new, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false),
      archive_cache: nil, focus_player: FakeFocus.new
    )
    @engine.start
    @engine.enqueue_now([track])
    wait_until { @audio.buffered_frames == CAPACITY }
  end

  def teardown
    @engine.shutdown
    @bus.reader.close unless @bus.reader.closed?
    @bus.instance_variable_get(:@writer).close
  end

  # Regression: levels analysed the newest decoded chunk, up to a ring buffer
  # ahead of the speakers. The first chunk (low tone) is what plays first.
  def test_levels_follow_the_played_frame_not_the_newest_decoded_chunk
    assert(@engine.levels.all?(&:zero?), 'nothing has played yet')

    @audio.play!(8_000)

    assert_operator peak(@engine.levels), :<=, 2, 'the first (80 Hz) chunk is playing'

    @audio.play!(chunk_frames + 4_000 - 8_000)

    assert_operator peak(@engine.levels), :>=, 12
  end

  # Regression: a full ring was polled every 5 ms with a write of the whole
  # pending chunk, and decoding resumed as soon as any space freed, so FM
  # emulation ran in small, cache-cold bursts.
  def test_full_ring_is_not_rewritten_until_a_refill_burst_fits
    writes = @audio.writes
    @audio.play!(1_000)
    sleep 0.05

    assert_equal writes, @audio.writes

    @audio.play!(CAPACITY / 2)
    wait_until { @audio.buffered_frames == CAPACITY }

    assert_operator @audio.writes - writes, :<=, 3
  end

  private

  def chunk_frames = RubyPlayer::DEFAULTS['audio']['decode_chunk_frames']
  def peak(levels) = levels.index(levels.max)

  def track
    RubyPlayer::Track.new(id: 1, folder_id: 1, physical_path: '/tmp/tone.raw', archive_entry: '',
                          subtune_index: 0, backend: 'fake', format: 'raw', title: 'Tone',
                          duration_ms: nil)
  end
end
