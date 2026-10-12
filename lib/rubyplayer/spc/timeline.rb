# frozen_string_literal: true

require_relative 'snapshot'

module RubyPlayer
  module Spc
    # S-DSP snapshots indexed by output-timeline frame, so the UI shows the
    # state being heard rather than the decoder's (up to ~0.85 s ahead).
    #
    # Same design as LevelTap: the decoder thread pushes each chunk's packed
    # records at the frame where the chunk starts playing; the UI asks for the
    # frame the device has played. Records stay packed until displayed.
    class Timeline
      FRAME_FORMAT = 'L<'
      private_constant :FRAME_FORMAT

      def initialize(retain_frames:)
        @retain_frames = retain_frames
        # Sorted [origin_frame, packed, count]; record frames are relative to
        # origin and ascend across segments.
        @segments = []
        @mutex = Mutex.new
      end

      def push(packed, count, origin_frame:)
        return if count.zero?

        @mutex.synchronize do
          # A flush discards buffered audio and later writes reuse its
          # timeline positions, so newer state replaces anything from there on.
          truncate_from(origin_frame)
          @segments << [origin_frame, packed, count]
          drop_before(absolute_frame(@segments.last, count - 1) - @retain_frames)
        end
      end

      # Latest snapshot heard at or before `frame`, with an absolute frame.
      def at(frame)
        @mutex.synchronize do
          @segments.reverse_each do |segment|
            origin, packed, count = segment
            next if origin > frame

            index = last_index_at_or_before(segment, count, frame)
            next unless index

            snapshot = Snapshot.unpack(packed, index)
            return snapshot.with(frame: origin + snapshot.frame)
          end
          nil
        end
      end

      def reset
        @mutex.synchronize { @segments.clear }
      end

      private

      def absolute_frame(segment, index)
        segment[0] + segment[1].unpack1(FRAME_FORMAT, offset: index * Snapshot::SIZE)
      end

      def last_index_at_or_before(segment, count, frame)
        after = (0...count).bsearch { |index| absolute_frame(segment, index) > frame } || count
        after.zero? ? nil : after - 1
      end

      def truncate_from(frame)
        while (segment = @segments.last)
          keep = (0...segment[2]).bsearch { |index| absolute_frame(segment, index) >= frame } || segment[2]
          return if keep == segment[2]

          if keep.zero?
            @segments.pop
          else
            @segments[-1] = [segment[0], segment[1].byteslice(0, keep * Snapshot::SIZE), keep]
            return
          end
        end
      end

      def drop_before(frame)
        @segments.shift while @segments.size > 1 && absolute_frame(@segments.first, @segments.first[2] - 1) < frame
      end
    end
  end
end
