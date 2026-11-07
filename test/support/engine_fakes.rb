require 'rubyplayer/audio_format'

module TestSupport
  # Stand-ins for PlaybackEngine's collaborators, shared by the engine tests
  # that drive it without a library database, Focus process or audio device.
  module EngineFakes
    # An audio ring the test drains by hand with play!, so output timing is
    # exact: frames count as played only when the test says so.
    class ManualRing
      attr_reader :sample_rate, :frames_played, :writes

      def initialize(sample_rate:, capacity_frames:)
        @sample_rate = sample_rate
        @capacity_frames = capacity_frames
        @frames_played = 0
        @buffered = 0
        @writes = 0
        @mutex = Mutex.new
      end

      def start; end
      def paused=(_value); end
      def flush = @mutex.synchronize { @buffered = 0 }
      def buffered_frames = @mutex.synchronize { @buffered }
      def writable_frames = @mutex.synchronize { @capacity_frames - @buffered }

      def write(data)
        @mutex.synchronize do
          @writes += 1
          accepted = [data.bytesize / RubyPlayer::AudioFormat::BYTES_PER_FRAME, @capacity_frames - @buffered].min
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

    # A permanently full ring: playback never consumes these fake writes,
    # and the test sets frames_played to move the output clock.
    class FullRing
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
      def writable_frames = 0
      def buffered_frames = 0
    end

    # The Library calls the engine makes during playback, all no-ops.
    class NullLibrary
      def rating_of(_id) = nil
      def record_history(**); end
      # Keep this fake method named after the production library API.
      # rubocop:disable Naming/AccessorMethodName
      def set_errored(_id); end
      # rubocop:enable Naming/AccessorMethodName
    end

    class NullFocus
      def stop; end
    end
  end
end
