# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'rubyplayer/audio_output'
require 'rubyplayer/playback_engine'
require_relative 'support/vgm_builder'

class PlaybackEngineVgmTest < Minitest::Test
  class FakeAudio
    attr_reader :sample_rate
    attr_accessor :frames_played

    def initialize(sample_rate: 48_000)
      @sample_rate = sample_rate
      @frames_played = 0
    end

    def start; end
    def paused=(_value); end
    def flush; end
    def write(_data) = 0
  end

  class FakeHandle
    attr_reader :seeks, :reads

    def initialize(seek_result: true)
      @seek_result = seek_result
      @seeks = []
      @reads = 0
    end

    def read(frames)
      @reads += 1
      ([0.0] * frames * 2).pack('e*')
    end

    def seek(milliseconds)
      @seeks << milliseconds
      @seek_result
    end

    def close; end
  end

  class FakeBackend
    attr_reader :handles

    def initialize(seek_result: true)
      @seek_result = seek_result
      @handles = []
    end

    def open(_path, _subtune, sample_rate:)
      handle = FakeHandle.new(seek_result: @seek_result)
      @handles << [handle, sample_rate]
      handle
    end
  end

  class Registry
    def initialize(backend) = @backend = backend
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

  class FakeArchiveCache
    attr_reader :calls

    def initialize(path)
      @path = path
      @calls = []
    end

    def materialize(physical_path, entry)
      @calls << [physical_path, entry]
      @path
    end
  end

  def setup
    @tmp = Dir.mktmpdir
    @path = File.join(@tmp, 'tone.vgm')
    File.binwrite(@path, VgmBuilder.new(ym2612_clock: 7_670_454).wait(100_000).end.bytes)
    @audio = FakeAudio.new
    @backend = FakeBackend.new
    @bus = RubyPlayer::EventBus.new
    @archive_cache = FakeArchiveCache.new(@path)
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: Registry.new(@backend), audio: @audio,
      library: FakeLibrary.new, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false),
      archive_cache: @archive_cache, focus_player: FakeFocus.new
    )
    @engine.start
  end

  def teardown
    @engine.shutdown
    @bus.reader.close unless @bus.reader.closed?
    @bus.instance_variable_get(:@writer).close
    FileUtils.remove_entry(@tmp)
  end

  def test_request_tracks_consumed_audio_not_decode_ahead_and_uses_integer_sample_math
    @engine.enqueue_now([track])
    wait_until { @engine.state[:playing] }
    wait_until { @backend.handles.first.first.reads.positive? }

    first = @engine.vgm_telemetry_request
    @audio.frames_played = 4_800
    second = @engine.vgm_telemetry_request

    assert_equal 0, first.sample
    assert_equal 4_410, second.sample
    assert_equal first.source.generation, second.source.generation
  end

  def test_seek_revisions_only_advance_after_success_and_restart_keeps_same_generation
    @engine.enqueue_now([track])
    wait_until { @engine.state[:playing] }
    before = @engine.vgm_telemetry_request
    @engine.seek(1_234)
    wait_until { @backend.handles.first.first.seeks.any? }
    after = @engine.vgm_telemetry_request

    assert_equal before.revision + 1, after.revision
    assert_equal (1_234 * 44_100) / 1_000, after.sample
    assert_equal before.source.generation, after.source.generation

    @engine.previous
    wait_until { @backend.handles.first.first.seeks.last.zero? }
    restarted = @engine.vgm_telemetry_request

    assert_equal after.revision + 1, restarted.revision
    assert_equal after.source.generation, restarted.source.generation
  end

  def test_failed_seek_does_not_change_the_telemetry_revision
    @backend = FakeBackend.new(seek_result: false)
    @engine.shutdown
    @engine = build_engine
    @engine.start
    @engine.enqueue_now([track])
    wait_until { @engine.state[:playing] }
    before = @engine.vgm_telemetry_request

    @engine.seek(1_234)
    wait_until { @backend.handles.first.first.seeks.any? }

    assert_equal before, @engine.vgm_telemetry_request
  end

  def test_pause_preserves_the_last_consumed_sample_and_replay_gets_a_new_generation
    item = track
    @engine.enqueue_now([item, item])
    wait_until { @engine.state[:playing] }
    @audio.frames_played = 4_800
    before_pause = @engine.vgm_telemetry_request
    @engine.toggle_play
    wait_until { @engine.state[:paused] }
    paused = @engine.vgm_telemetry_request
    @engine.toggle_play
    wait_until { !@engine.state[:paused] }
    @engine.skip
    wait_until { @engine.vgm_telemetry_request&.source&.generation == before_pause.source.generation + 1 }
    replayed = @engine.vgm_telemetry_request

    assert paused.paused
    assert_equal before_pause.sample, paused.sample
    assert_equal before_pause.source.generation + 1, replayed.source.generation
  end

  def test_archive_request_uses_the_path_materialized_when_playback_opened
    archived = track(physical_path: File.join(@tmp, 'album.zip'), archive_entry: 'disc/tone.vgm')
    @engine.enqueue_now([archived])
    wait_until { @engine.state[:playing] }

    request = @engine.vgm_telemetry_request
    @engine.vgm_telemetry_request

    assert_equal @path, request.source.path
    assert_equal [[archived.physical_path, archived.archive_entry]], @archive_cache.calls
  end

  def test_non_vgm_and_stopped_playback_have_no_telemetry_request
    File.binwrite(@path, 'not a VGM')
    @engine.enqueue_now([track(format: 'gbs')])
    wait_until { @engine.state[:playing] }

    assert_nil @engine.vgm_telemetry_request

    @engine.stop

    assert_nil @engine.vgm_telemetry_request
  end

  private

  def build_engine
    RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: Registry.new(@backend), audio: @audio,
      library: FakeLibrary.new, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false),
      archive_cache: @archive_cache, focus_player: FakeFocus.new
    )
  end

  def track(format: 'vgm', physical_path: @path, archive_entry: '')
    RubyPlayer::Track.new(id: 1, folder_id: 1, physical_path: physical_path,
                          archive_entry: archive_entry, subtune_index: 0, backend: 'gme',
                          format: format, title: 'fixture', duration_ms: 10_000)
  end
end
