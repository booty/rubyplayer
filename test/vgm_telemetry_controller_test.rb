# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/vgm/snapshot'
require 'rubyplayer/ui/vgm_telemetry_controller'

class VgmTelemetryControllerTest < Minitest::Test
  Source = RubyPlayer::Vgm::Source
  Request = RubyPlayer::Vgm::Request
  Snapshot = RubyPlayer::Vgm::Snapshot

  class FakeEngine
    attr_accessor :request

    def vgm_telemetry_request = @request
  end

  class FakeTelemetry
    attr_reader :requests, :suspends, :shutdowns

    def initialize
      @requests = []
      @suspends = 0
      @shutdowns = 0
    end

    def request(request) = @requests << request
    def suspend = @suspends += 1
    def shutdown = @shutdowns += 1
  end

  def setup
    @engine = FakeEngine.new
    @telemetry = FakeTelemetry.new
    @now = 0.0
    @controller = RubyPlayer::UI::VgmTelemetryController.new(
      engine: @engine, telemetry: @telemetry, refresh_hz: 15, clock: -> { @now }
    )
    @controller.visible = true
    @engine.request = request(sample: 100)
  end

  def teardown
    @controller.shutdown
  end

  def test_requests_immediately_then_at_rate_and_never_recurs_while_paused
    @controller.tick
    @controller.tick

    assert_equal [100], @telemetry.requests.map(&:sample)

    @engine.request = request(sample: 200)
    @now = 0.07
    @controller.tick

    assert_equal [100, 200], @telemetry.requests.map(&:sample)

    @engine.request = request(sample: 200, paused: true)
    @now = 1.0
    @controller.tick
    @now = 2.0
    @controller.tick

    assert_equal 2, @telemetry.requests.length
  end

  # Replay is resumable: a request may return short of its target. While
  # paused the engine sample stops moving, so the controller must keep asking
  # until the snapshot catches up, then go quiet again.
  def test_paused_view_keeps_requesting_until_replay_catches_up
    @engine.request = request(sample: 50_000, paused: true)
    @controller.tick

    assert @controller.accept(snapshot(sample: 10_000))
    @now = 0.01
    @controller.tick

    assert_equal 1, @telemetry.requests.length

    @now = 0.07
    @controller.tick

    assert_equal 2, @telemetry.requests.length
    assert_in_delta 1.0 / 15, @controller.seconds_until_due, 0.0001
    assert @controller.accept(snapshot(sample: 50_000))
    @now = 1.0
    @controller.tick

    assert_equal 2, @telemetry.requests.length
    assert_nil @controller.seconds_until_due
  end

  def test_revision_change_clears_old_output_and_rejects_stale_results
    @controller.tick

    assert @controller.accept(snapshot(sample: 100))
    @engine.request = request(sample: 20, revision: 1)
    @now = 0.01
    @controller.tick

    assert_nil @controller.snapshot
    refute @controller.accept(snapshot(sample: 150, revision: 0))
    assert_equal 2, @telemetry.requests.length
  end

  def test_same_revision_accepts_useful_behind_snapshot_but_rejects_future_and_regression
    @controller.tick
    @engine.request = request(sample: 20_000)
    @now = 0.07
    @controller.tick

    assert @controller.accept(snapshot(sample: 13_000))
    refute @controller.accept(snapshot(sample: 20_001))
    refute @controller.accept(snapshot(sample: 12_999))
    assert_equal 'Catching up', @controller.snapshot.message
  end

  def test_hidden_view_suspends_and_reopening_requests_current_position
    @controller.tick
    @controller.visible = false
    @engine.request = request(sample: 400)
    @now = 1.0
    @controller.tick

    assert_nil @controller.snapshot
    assert_equal 1, @telemetry.suspends

    @controller.visible = true
    @controller.tick

    assert_equal [100, 400], @telemetry.requests.map(&:sample)
  end

  def test_terminal_result_stops_automatic_retries_until_revision_changes
    @controller.tick

    assert @controller.accept(snapshot(status: :error, sample: 100, message: 'bad stream'))
    @now = 10.0
    @controller.tick

    assert_equal 1, @telemetry.requests.length

    @engine.request = request(sample: 0, revision: 1)
    @controller.tick

    assert_equal 2, @telemetry.requests.length
  end

  private

  def request(sample:, revision: 0, generation: 1, paused: false)
    source = Source.new(generation: generation, track_identity: [generation, '/tmp/live.vgm', '', 0],
                        path: '/tmp/live.vgm', format: :vgm, sample_rate: 44_100,
                        timeline_policy: :libgme_vgm_samples, decoder_capabilities: {})
    Request.new(source: source, revision: revision, sample: sample, paused: paused)
  end

  def snapshot(sample:, revision: 0, generation: 1, status: :ready, message: nil)
    Snapshot.new(generation: generation, revision: revision, sample: sample, status: status,
                 message: message, loop_count: 0, chips: [], warnings: [])
  end
end
