# frozen_string_literal: true

module RubyPlayer
  # Native chip-state snapshots (S-DSP for SPC, APU for GBS) indexed by
  # output-timeline frame, so the UI shows the state being heard rather than
  # the decoder's (up to ~0.85 s ahead).
  #
  # Like LevelTap: the decoder thread pushes each chunk's packed records at
  # the output frame where the chunk starts playing; the UI asks for the
  # frame the device has played. Records stay packed until displayed. A
  # record class (Spc::Snapshot, Gbs::Snapshot) unpacks them; each starts
  # with its uint32 frame offset.
  #
  # Pushes only append. Records may be tagged beyond their own chunk
  # (libgme emulates ahead), and that state stays valid while playback is
  # continuous, so discontinuities (seek, track change) call #reset instead.
  # Emulation is monotonic, so record frames never decrease across pushes.
  class ChipTimeline
    # One pushed chunk. Record frames are offsets from origin_frame.
    Segment = Struct.new(:origin_frame, :packed_records, :record_count, :record)
    # Each chunk is ~340 ms at default settings, so this keeps ~85 s of
    # snapshots when nobody reads (live page closed).
    DEFAULT_MAX_SEGMENTS = 256
    FRAME_OFFSET_FORMAT = 'L<'
    private_constant :DEFAULT_MAX_SEGMENTS, :FRAME_OFFSET_FORMAT

    def initialize(max_segments: DEFAULT_MAX_SEGMENTS, record: nil)
      @max_segments = max_segments
      @record = record
      @segments = []
      # Records of the first segment already returned by #take_through.
      @taken = 0
      @mutex = Mutex.new
    end

    def push(packed_records, record_count, origin_frame:, record: @record)
      return if record_count.zero?

      @mutex.synchronize do
        @segments << Segment.new(origin_frame, packed_records, record_count, record)
        while @segments.size > @max_segments
          @segments.shift
          @taken = 0
        end
      end
    end

    # Latest snapshot heard at or before `output_frame`, carrying its
    # absolute output frame. Discards segments before the one it returns:
    # between resets the device only moves forward. Pruning here, not by
    # distance from the newest push, matters because silence lookahead can
    # push records seconds ahead of what is being heard.
    def at(output_frame)
      @mutex.synchronize do
        @segments.each_index.reverse_each do |segment_index|
          segment = @segments[segment_index]
          next if segment.origin_frame > output_frame

          record_index = last_record_at_or_before(segment, output_frame)
          next unless record_index

          drop_segments(segment_index)
          return unpack(segment, record_index)
        end
        nil
      end
    end

    # Every snapshot heard up to `output_frame` that no earlier call
    # returned, oldest first, at most `limit` (the newest). For views that
    # must see each state change, not just the latest.
    def take_through(output_frame, limit:)
      @mutex.synchronize do
        taken = []
        while (segment = @segments.first)
          count = records_through(segment, output_frame)
          (@taken...count).each { |index| taken << [segment, index] }
          @taken = [count, @taken].max
          break if count < segment.record_count

          @segments.shift
          @taken = 0
        end
        taken.last(limit).map { |taken_segment, index| unpack(taken_segment, index) }
      end
    end

    def reset
      @mutex.synchronize do
        @segments.clear
        @taken = 0
      end
    end

    private

    def unpack(segment, record_index)
      snapshot = segment.record.unpack(segment.packed_records, record_index)
      snapshot.with(frame: segment.origin_frame + snapshot.frame)
    end

    def drop_segments(count)
      return if count.zero?

      @segments.shift(count)
      @taken = 0
    end

    def output_frame_of(segment, record_index)
      segment.origin_frame +
        segment.packed_records.unpack1(FRAME_OFFSET_FORMAT, offset: record_index * segment.record::SIZE)
    end

    # Records of `segment` heard at or before output_frame.
    def records_through(segment, output_frame)
      return 0 if segment.origin_frame > output_frame

      (0...segment.record_count).bsearch { |index| output_frame_of(segment, index) > output_frame } ||
        segment.record_count
    end

    def last_record_at_or_before(segment, output_frame)
      after = records_through(segment, output_frame)
      after.zero? ? nil : after - 1
    end
  end
end
