# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'zlib'
require 'stringio'
require 'rubyplayer/event_bus'
require 'rubyplayer/playback_engine'
require 'rubyplayer/vgm/reader'
require 'rubyplayer/vgm/cursor'
require 'rubyplayer/vgm/telemetry'
require 'rubyplayer/ui/vgm_live_view'
require 'rubyplayer/ui/vgm_telemetry_controller'
require_relative 'support/vgm_builder'

class VgmRealtimeIntegrationTest < Minitest::Test
  class FakeAudio
    attr_reader :sample_rate
    attr_accessor :frames_played

    def initialize
      @sample_rate = 48_000
      @frames_played = 0
    end

    def start; end
    def paused=(_value); end
    def flush; end
    def write(_data) = 0
    # A permanently full ring: playback never consumes these fake writes.
    def writable_frames = 0
    def buffered_frames = 0
  end

  class FakeHandle
    def read(frames) = ([0.0] * frames * 2).pack('e*')
    # This fake mirrors the backend's side-effecting seek success result.
    # rubocop:disable Naming/PredicateMethod, Naming/MethodParameterName
    def seek(_ms) = true
    # rubocop:enable Naming/PredicateMethod, Naming/MethodParameterName
    def close; end
  end

  class FakeBackend
    def open(_path, _subtune, **_options) = FakeHandle.new
  end

  class FakeRegistry
    def backend_for(_path) = FakeBackend.new
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
    @tmp = Dir.mktmpdir
  end

  def teardown
    @controller&.shutdown
    @engine&.shutdown
    if @bus
      @bus.reader.close unless @bus.reader.closed?
      @bus.instance_variable_get(:@writer).close
    end
    FileUtils.remove_entry(@tmp)
  end

  def test_real_fixtures_change_register_derived_channel_and_patch_state
    fixtures = [
      ['alisa-dragoon-introduction.vgm', 0, :key_on],
      ['scrap-brean-zone.vgm', 2, :key_off]
    ]
    fixtures.each do |name, channel_index, initial_state|
      reader = RubyPlayer::Vgm::Reader.open(File.join(FIXTURES, name), max_bytes: 64 * 1024 * 1024)
      cursor = RubyPlayer::Vgm::Cursor.new(reader: reader)
      initial = cursor.advance_to(sample: 0)
      later = cursor.advance_to(sample: 44_100)
      chip = ->(snapshot) { snapshot.chips.find { |item| item.id == 'ym2612:0' } }
      before = chip.call(initial).channels.fetch(channel_index)
      after = chip.call(later).channels.fetch(channel_index)

      # Independent byte inspection: Alisa's channel-1 key-on is the YM2612
      # 0x28 write at 0xB4D; Scrap Brean reaches channel 3's later key-on at
      # 0x2DDB. These offsets anchor the decoded row expectations.
      assert_equal initial_state, before.state, name
      assert_equal :key_on, after.state, name
      refute_equal before.patch.short_digest, after.patch.short_digest, name
    end
  end

  def test_plain_gzip_and_materialized_archive_streams_have_equivalent_replay
    plain = File.join(FIXTURES, 'alisa-dragoon-introduction.vgm')
    bytes = File.binread(plain)
    compressed = File.join(@tmp, 'same-data.bin')
    Zlib::GzipWriter.open(compressed) { |gzip| gzip.write(bytes) }
    archive = File.join(@tmp, 'vgm-fixture.zip')
    system('bsdtar', '-cf', archive, '--format', 'zip', '-C', File.dirname(plain),
           File.basename(plain), exception: true)
    cache = RubyPlayer::ArchiveCache.new(root: File.join(@tmp, 'cache'))
    materialized = cache.materialize(archive, File.basename(plain))
    paths = [plain, compressed, materialized]
    snapshots = paths.map do |path|
      reader = RubyPlayer::Vgm::Reader.open(path, max_bytes: 64 * 1024 * 1024)
      RubyPlayer::Vgm::Cursor.new(reader: reader).advance_to(sample: 44_100)
    end

    assert(paths.all? { |path| RubyPlayer::Vgm::Reader.vgm_stream?(path) })
    assert_equal snapshots.first.chips, snapshots[1].chips
    assert_equal snapshots.first.chips, snapshots[2].chips
  end

  def test_fake_audio_engine_worker_controller_and_widget_share_consumed_sample_time
    path = write_timeline_fixture
    start_timeline_playback(path)
    @controller.visible = true
    @controller.tick

    assert_channel_state(sample: 0, state: :key_on)

    @audio.frames_played = 48_000
    @now = 0.07
    @controller.tick

    assert_channel_state(sample: 44_100, state: :key_off)

    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 12, cols: 90)
    @widget.render(screen, x: 0, y: 0, width: 90, height: 12,
                           theme: RubyPlayer::Theme::DEFAULT, now_sample: 44_100)
    rendered = screen.instance_variable_get(:@back).map { |row| row.map(&:ch).join }.join("\n")

    assert_match(/^1 FM 1 .* key off/, rendered)
  end

  private

  def write_timeline_fixture
    path = File.join(@tmp, 'timeline.vgm')
    bytes = VgmBuilder.new(ym2612_clock: 7_670_454)
                      .ym2612(0, 0x28, 0xf0).wait(100).ym2612(0, 0x28, 0x00).wait(500_000).end.bytes
    File.binwrite(path, bytes)
    path
  end

  def start_timeline_playback(path)
    @audio = FakeAudio.new
    @bus = RubyPlayer::EventBus.new
    config = RubyPlayer::ConfigStore.new(path: '/nonexistent.rb', create_if_missing: false)
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: FakeRegistry.new, audio: @audio,
      library: FakeLibrary.new, event_bus: @bus, config: config, focus_player: FakeFocus.new
    )
    @telemetry = RubyPlayer::Vgm::Telemetry.new(event_bus: @bus, max_bytes: 1_048_576)
    @now = 0.0
    @controller = RubyPlayer::UI::VgmTelemetryController.new(
      engine: @engine, telemetry: @telemetry, refresh_hz: 15, clock: -> { @now }
    )
    @widget = RubyPlayer::UI::VgmLiveView.new
    @engine.start
    track = RubyPlayer::Track.new(id: 1, folder_id: 1, physical_path: path,
                                  archive_entry: '', subtune_index: 0, backend: 'gme',
                                  format: 'vgm', title: 'Timeline')
    @engine.enqueue_now([track])
    wait_until { @engine.state[:playing] }
  end

  def assert_channel_state(sample:, state:)
    snapshot = wait_for_snapshot(sample: sample)

    assert_equal sample, snapshot.sample
    assert_equal state, channel(snapshot).state
  end

  def wait_for_snapshot(sample:)
    wait_until(timeout: 5, interval: 0.01, failure_message: "no accepted snapshot at #{sample}") do
      events = @bus.drain
      events.each do |type, payload|
        next unless type == :vgm_telemetry_ready && payload[:telemetry].equal?(@telemetry)

        snapshot = @telemetry.take_snapshot
        @widget.update(@controller.snapshot) if @controller.accept(snapshot)
      end
      snapshot = @controller.snapshot
      snapshot if snapshot&.sample == sample
    end
  end

  def channel(snapshot)
    snapshot.chips.find { |chip| chip.id == 'ym2612:0' }.channels.first
  end
end
