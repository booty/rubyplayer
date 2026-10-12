# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/spc/snapshot'
require 'rubyplayer/spc/timeline'

class SpcTimelineTest < Minitest::Test
  Snapshot = RubyPlayer::Spc::Snapshot

  def setup
    @timeline = RubyPlayer::Spc::Timeline.new(retain_frames: 100_000)
  end

  def test_at_returns_the_latest_snapshot_heard_by_a_frame
    @timeline.push(*records([0, 'a'], [2_400, 'b'], [4_800, 'c']), origin_frame: 1_000)

    assert_nil @timeline.at(999)
    assert_equal 'a', marker(@timeline.at(1_000))
    assert_equal 'a', marker(@timeline.at(3_399))
    assert_equal 'b', marker(@timeline.at(3_400))
    assert_equal 'c', marker(@timeline.at(1_000_000))
  end

  def test_lookups_span_segments
    @timeline.push(*records([0, 'a'], [2_400, 'b']), origin_frame: 0)
    @timeline.push(*records([400, 'c'], [2_800, 'd']), origin_frame: 4_000)

    assert_equal 'b', marker(@timeline.at(4_399))
    assert_equal 'c', marker(@timeline.at(4_400))
    assert_equal 'd', marker(@timeline.at(7_000))
  end

  # Snapshot frames are absolute output positions: the decoded frame carries
  # the timeline origin of its chunk.
  def test_returned_snapshot_frame_is_absolute
    @timeline.push(*records([500, 'a']), origin_frame: 10_000)

    assert_equal 10_500, @timeline.at(10_600).frame
  end

  # A flush discards buffered audio and later writes reuse its positions, so
  # a push replaces every stored snapshot at or after its origin, including
  # lookahead records an earlier segment placed beyond its own chunk.
  def test_push_replaces_snapshots_at_or_after_its_origin
    @timeline.push(*records([0, 'a'], [2_400, 'b'], [20_000, 'lookahead']), origin_frame: 0)
    @timeline.push(*records([100, 'new']), origin_frame: 2_000)

    assert_equal 'a', marker(@timeline.at(2_099))
    assert_equal 'new', marker(@timeline.at(2_100))
    assert_equal 'new', marker(@timeline.at(30_000))
  end

  def test_retention_drops_old_segments
    timeline = RubyPlayer::Spc::Timeline.new(retain_frames: 5_000)
    timeline.push(*records([0, 'old']), origin_frame: 0)
    timeline.push(*records([0, 'new']), origin_frame: 10_000)

    assert_nil timeline.at(5_000)
    assert_equal 'new', marker(timeline.at(10_000))
  end

  def test_empty_pushes_and_reset
    @timeline.push('', 0, origin_frame: 0)

    assert_nil @timeline.at(0)
    @timeline.push(*records([0, 'a']), origin_frame: 0)
    @timeline.reset

    assert_nil @timeline.at(10)
  end

  private

  # Builds packed rp_spc_snapshot records; regs[0] carries a one-byte marker.
  def records(*specs)
    packed = specs.map do |frame, label|
      regs = Array.new(128, 0)
      regs[0] = label.sum % 256
      @labels ||= {}
      @labels[regs[0]] = label
      [frame, *regs, *Array.new(8, 0), *Array.new(8, 0), *Array.new(8, 0), 0].pack(Snapshot::FORMAT)
    end.join
    [packed, specs.size]
  end

  def marker(snapshot) = snapshot && @labels.fetch(snapshot.regs[0])
end
