# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/spc/snapshot'
require 'rubyplayer/chip_timeline'
require 'rubyplayer/gbs/snapshot'
require 'rubyplayer/backends/snes_spc'

class ChipTimelineTest < Minitest::Test
  Snapshot = RubyPlayer::Spc::Snapshot

  def setup
    @timeline = RubyPlayer::ChipTimeline.new(record: Snapshot)
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

  # Regression: every push truncated at its origin as if it followed a
  # flush, deleting the previous chunk's records tagged past its own end
  # (valid lookahead during continuous playback), so state went stale at
  # every chunk boundary.
  def test_appending_keeps_records_tagged_past_their_chunk
    @timeline.push(*records([0, 'a'], [2_400, 'b'], [16_800, 'lookahead']), origin_frame: 0)
    @timeline.push(*records([2_816, 'next']), origin_frame: 16_384)

    assert_equal 'lookahead', marker(@timeline.at(16_800))
    assert_equal 'next', marker(@timeline.at(19_200))
  end

  def test_real_native_records_survive_across_adjacent_chunks
    handle = RubyPlayer::Backends::SnesSpc.new.open(File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc'), 0,
                                                    sample_rate: 48_000)
    frames = []
    5.times do |chunk|
      handle.read(16_384)
      packed, count = handle.take_snapshots
      origin = chunk * 16_384
      frames.concat(Array.new(count) { |index| origin + Snapshot.unpack(packed, index).frame })
      @timeline.push(packed, count, origin_frame: origin)
    end

    frames.uniq.each { |frame| assert_equal frame, @timeline.at(frame).frame }
  ensure
    handle&.close
  end

  # Regression: retention counted back from the newest record, and silence
  # lookahead emulates seconds ahead, so the segment being heard was evicted
  # and the page fell back to "Waiting for SPC state".
  def test_a_segment_far_in_the_future_does_not_evict_the_one_being_heard
    @timeline.push(*records([0, 'now']), origin_frame: 0)
    @timeline.push(*records([0, 'later'], [300_000, 'far']), origin_frame: 16_384)

    assert_equal 'now', marker(@timeline.at(1_000))
  end

  # The device only moves forward between resets, so lookups discard
  # segments before the one being heard.
  def test_lookups_discard_segments_before_the_one_being_heard
    @timeline.push(*records([0, 'a']), origin_frame: 0)
    @timeline.push(*records([0, 'b']), origin_frame: 10_000)
    @timeline.push(*records([0, 'c']), origin_frame: 20_000)

    assert_equal 'c', marker(@timeline.at(20_500))
    assert_nil @timeline.at(5_000)
  end

  # Without lookups (live page closed), the segment cap bounds memory.
  def test_segment_count_is_capped_without_lookups
    timeline = RubyPlayer::ChipTimeline.new(max_segments: 4, record: Snapshot)
    10.times { |index| timeline.push(*records([0, "s#{index}"]), origin_frame: index * 1_000) }

    assert_nil timeline.at(5_999)
    assert_equal 's6', marker(timeline.at(6_000))
  end

  # take_through returns each heard record once, in order, across segments.
  def test_take_through_returns_every_heard_record_once
    @timeline.push(*records([0, 'a'], [2_400, 'b']), origin_frame: 0)
    @timeline.push(*records([400, 'c'], [2_800, 'd']), origin_frame: 4_000)

    assert_equal %w[a], taken(1_000)
    assert_equal %w[b c], taken(4_400)
    assert_empty taken(4_500)
    assert_equal [6_800], @timeline.take_through(10_000, limit: 10).map(&:frame)
  end

  def test_take_through_keeps_only_the_newest_records_past_the_limit
    @timeline.push(*records([0, 'a'], [10, 'b'], [20, 'c']), origin_frame: 0)

    assert_equal(%w[b c], @timeline.take_through(100, limit: 2).map { |snapshot| marker(snapshot) })
  end

  # Each push names its record class, so one timeline serves SPC and GBS.
  def test_records_unpack_with_the_class_they_were_pushed_with
    gbs = RubyPlayer::Gbs::Snapshot
    packed = [120, *Array.new(48, 7), 15, 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 70_224, 4_194_304].pack(gbs::FORMAT)
    @timeline.push(packed, 1, origin_frame: 1_000, record: gbs)

    snapshot = @timeline.at(2_000)

    assert_kind_of gbs, snapshot
    assert_equal 1_120, snapshot.frame
    assert_in_delta 59.73, snapshot.driver_hz, 0.01
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

  def taken(frame) = @timeline.take_through(frame, limit: 10).map { |snapshot| marker(snapshot) }
end
