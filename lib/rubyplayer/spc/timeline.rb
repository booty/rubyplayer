# frozen_string_literal: true

require_relative 'snapshot'

module RubyPlayer
  module Spc
    # S-DSP snapshots indexed by output-timeline frame, so the UI shows the
    # state being heard rather than the decoder's (up to ~0.85 s ahead).
    #
    # Like LevelTap: the decoder thread pushes each chunk's packed records at
    # the output frame where the chunk starts playing; the UI asks for the
    # frame the device has played. Records stay packed until displayed.
    #
    # Pushes only append. Records may be tagged beyond their own chunk
    # (libgme emulates ahead), and that state stays valid while playback is
    # continuous, so discontinuities (seek, track change) call #reset instead.
    class Timeline
      # One pushed chunk. Record frames are offsets from origin_frame.
      Segment = Struct.new(:origin_frame, :packed_records, :record_count)
      # Each chunk is ~340 ms at default settings, so this keeps ~85 s of
      # snapshots when nobody calls #at (live page closed).
      DEFAULT_MAX_SEGMENTS = 256
      FRAME_OFFSET_FORMAT = 'L<'
      private_constant :DEFAULT_MAX_SEGMENTS, :FRAME_OFFSET_FORMAT

      def initialize(max_segments: DEFAULT_MAX_SEGMENTS)
        @max_segments = max_segments
        @segments = []
        @mutex = Mutex.new
      end

      def push(packed_records, record_count, origin_frame:)
        return if record_count.zero?

        @mutex.synchronize do
          @segments << Segment.new(origin_frame, packed_records, record_count)
          @segments.shift while @segments.size > @max_segments
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

            @segments.shift(segment_index)
            snapshot = Snapshot.unpack(segment.packed_records, record_index)
            return snapshot.with(frame: segment.origin_frame + snapshot.frame)
          end
          nil
        end
      end

      def reset
        @mutex.synchronize { @segments.clear }
      end

      private

      def output_frame_of(segment, record_index)
        segment.origin_frame +
          segment.packed_records.unpack1(FRAME_OFFSET_FORMAT, offset: record_index * Snapshot::SIZE)
      end

      def last_record_at_or_before(segment, output_frame)
        after = (0...segment.record_count).bsearch { |index| output_frame_of(segment, index) > output_frame }
        after ||= segment.record_count
        after.zero? ? nil : after - 1
      end
    end
  end
end
