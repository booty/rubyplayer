# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/event_bus'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/vgm/cursor'
require 'rubyplayer/vgm/telemetry'
require_relative 'support/async_wait'

class VgmTelemetryTest < Minitest::Test
  Source = RubyPlayer::Vgm::Source
  Request = RubyPlayer::Vgm::Request

  FakeStat = Data.define(:dev, :ino, :size, :mtime)
  FakeLogger = Class.new { def error(_message); end }

  class ControlledCursor
    attr_reader :targets, :closed, :cancelled

    def initialize(entered: nil, release: nil)
      @entered = entered
      @release = release
      @gate_used = false
      @targets = Queue.new
      @closed = false
    end

    def advance_to(sample:, cancel:)
      @entered << sample if @entered
      if @release && !@gate_used
        @gate_used = true
        loop do
          @release.pop(true)
          break
        rescue ThreadError
          if cancel.call
            @cancelled = true
            raise RubyPlayer::Vgm::Cursor::Cancelled
          end

          sleep 0.001
        end
      end
      @targets << sample
      RubyPlayer::Vgm::Snapshot.new(generation: 0, revision: 0, sample: sample,
                                    status: :ready, message: nil, loop_count: 0,
                                    chips: [], warnings: [])
    end

    def close = @closed = true
  end

  def setup
    @bus = RubyPlayer::EventBus.new
    @source = source(generation: 1)
    @read_count = 0
    @cursors = []
    @stat = FakeStat.new(1, 1, 100, Time.at(0))
  end

  def teardown
    @telemetry&.shutdown
    @bus.reader.close unless @bus.reader.closed?
    @bus.instance_variable_get(:@writer).close
  end

  def test_worker_is_lazy_and_same_revision_targets_coalesce_behind_active_replay
    entered = Queue.new
    release = Queue.new
    @telemetry = telemetry(cursor_options: { entered: entered, release: release })

    assert_empty @cursors

    @telemetry.request(request(sample: 1))

    assert_equal 1, entered.pop
    2.upto(101) { |sample| @telemetry.request(request(sample: sample)) }
    release << true
    wait_until { @cursors.first.targets.size >= 1 }
    wait_until { @cursors.first.targets.size >= 2 }

    snapshot = @telemetry.take_snapshot

    assert_equal 101, snapshot.sample
    assert_equal(1, @bus.drain.count { |type, _| type == :vgm_telemetry_ready })
  end

  def test_new_revision_cancels_active_replay_and_publishes_only_current_revision
    entered = Queue.new
    release = Queue.new
    @telemetry = telemetry(cursor_options: { entered: entered, release: release })
    @telemetry.request(request(sample: 100))
    entered.pop
    @telemetry.request(request(sample: 2, revision: 1))
    wait_until { @cursors.first.cancelled }
    wait_until { @cursors.first.targets.size >= 1 }

    snapshot = @telemetry.take_snapshot

    assert_equal 1, snapshot.revision
    assert_equal 2, snapshot.sample
  end

  def test_suspend_cancels_replay_closes_source_and_reopen_delivers_fresh_generation
    entered = Queue.new
    release = Queue.new
    @telemetry = telemetry(cursor_options: { entered: entered, release: release })
    @telemetry.request(request(sample: 100))
    entered.pop
    @telemetry.suspend
    @telemetry.request(request(sample: 3, generation: 2))

    assert_equal 3, entered.pop
    release << true
    wait_until { @cursors.size >= 2 && @cursors.last.targets.size >= 1 }

    snapshot = @telemetry.take_snapshot

    assert @cursors.first.closed
    assert_equal 2, snapshot.generation
    assert_equal 3, snapshot.sample
  end

  def test_notification_token_stays_coalesced_across_suspend_and_reopen
    @telemetry = telemetry
    @telemetry.request(request(sample: 5))
    wait_until { @telemetry.take_snapshot&.sample == 5 }
    @bus.drain
    # Put a fresh token in the bus while preserving a pending snapshot.
    @telemetry.request(request(sample: 6))
    wait_until { @bus.instance_variable_get(:@queue).size == 1 }
    @telemetry.suspend
    @telemetry.request(request(sample: 7, generation: 2))
    wait_until { @telemetry.instance_variable_get(:@snapshot)&.sample == 7 }

    snapshot = @telemetry.take_snapshot
    events = @bus.drain

    assert_equal 7, snapshot.sample
    assert_equal(1, events.count { |type, _| type == :vgm_telemetry_ready })
  end

  def test_reader_failure_publishes_one_error_and_is_not_retried_for_same_source
    @telemetry = telemetry(reader_error: RubyPlayer::Vgm::Reader::ReadError.new('bad VGM'))
    @telemetry.request(request(sample: 9))
    wait_until { @telemetry.instance_variable_get(:@snapshot) }

    first = @telemetry.take_snapshot
    @bus.drain

    assert_equal :error, first.status
    assert_match 'bad VGM', first.message
    @telemetry.request(request(sample: 10))
    wait_until { @telemetry.instance_variable_get(:@snapshot) }

    assert_equal 1, @read_count
    assert_equal 10, @telemetry.take_snapshot.sample
    assert_equal(1, @bus.drain.count { |type, _| type == :vgm_telemetry_ready })

    @telemetry.suspend
    @telemetry.request(request(sample: 11))
    wait_until { @telemetry.instance_variable_get(:@snapshot) }

    assert_equal 2, @read_count
    assert_equal :error, @telemetry.take_snapshot.status
  end

  def test_changed_source_signature_fails_reuse_and_snapshots_stay_frozen
    @telemetry = telemetry
    @telemetry.request(request(sample: 5))
    wait_until { @telemetry.instance_variable_get(:@snapshot) }
    first = @telemetry.take_snapshot
    @bus.drain

    assert_predicate first.chips, :frozen?

    @stat = FakeStat.new(@stat.dev, @stat.ino, @stat.size + 1, @stat.mtime)
    @telemetry.request(request(sample: 6))
    wait_until { @telemetry.instance_variable_get(:@snapshot) }

    assert @cursors.first.closed
    assert_equal :error, @telemetry.take_snapshot.status
  end

  def test_shutdown_cancels_an_active_reader_open_before_joining_worker
    entered = Queue.new
    release = Queue.new
    reader_factory = lambda do |_path, cancel:, **_options|
      entered << cancel
      release.pop
      raise RubyPlayer::Vgm::Reader::Cancelled if cancel.call

      Object.new
    end
    @telemetry = telemetry(reader_factory: reader_factory)
    @telemetry.request(request(sample: 1))
    cancel = entered.pop
    shutdown = Thread.new { @telemetry.shutdown }
    wait_until { @telemetry.instance_variable_get(:@shutdown) }
    release << true
    shutdown.join

    assert cancel.call
    assert_nil @telemetry.instance_variable_get(:@thread)
  end

  private

  def source(generation: 1)
    Source.new(generation: generation, track_identity: [generation, '/tmp/fixture.vgm', '', 0],
               path: '/tmp/fixture.vgm', format: :vgm, sample_rate: 44_100,
               timeline_policy: :vgm_samples, decoder_capabilities: {})
  end

  def request(sample:, revision: 0, generation: 1)
    Request.new(source: source(generation: generation), revision: revision,
                sample: sample, paused: false)
  end

  def telemetry(cursor_options: {}, reader_error: nil, reader_factory: nil)
    RubyPlayer::Vgm::Telemetry.new(
      event_bus: @bus, max_bytes: 1024,
      reader_factory: reader_factory || lambda do |_path, **_options|
        @read_count += 1
        raise reader_error if reader_error

        Object.new
      end,
      cursor_factory: lambda do |_reader, **_options|
        cursor = ControlledCursor.new(**cursor_options)
        @cursors << cursor
        cursor
      end,
      stat_factory: ->(_path) { @stat },
      logger: FakeLogger.new
    )
  end
end
