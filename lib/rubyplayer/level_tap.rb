# frozen_string_literal: true

require_relative 'audio_format'

module RubyPlayer
  # EQ animation source: per-band magnitudes of the audio being played right
  # now, via the Goertzel algorithm at log-spaced frequencies.
  #
  # push() runs on the decoder thread as audio enters the output ring, tagged
  # with the output-timeline frame where it will play. levels() runs on the
  # UI thread and analyses the window ending at the frame the device has
  # played. Analysing the newest decoded audio instead would run a ring buffer
  # ahead of the speakers and only change once per decode burst, which made
  # large decode chunks (cheaper for FM emulation) look choppy.
  class LevelTap
    DEFAULT_BANDS = 16
    DEFAULT_SAMPLE_RATE = 48_000
    DEFAULT_WINDOW_FRAMES = 512
    # Enough for a default ring buffer plus one large decode chunk; callers
    # with other sizes pass their own bound.
    DEFAULT_RETAIN_FRAMES = 2 * DEFAULT_SAMPLE_RATE
    LOW_FREQUENCY_HZ = 60.0
    MAX_FREQUENCY_HZ = 12_000.0
    NYQUIST_RATIO = 0.45
    STEREO_CHANNELS = AudioFormat::CHANNELS
    FRAME_BYTES = AudioFormat::BYTES_PER_FRAME
    private_constant :DEFAULT_BANDS, :DEFAULT_SAMPLE_RATE, :DEFAULT_WINDOW_FRAMES,
                     :DEFAULT_RETAIN_FRAMES, :LOW_FREQUENCY_HZ, :MAX_FREQUENCY_HZ,
                     :NYQUIST_RATIO, :STEREO_CHANNELS, :FRAME_BYTES

    def initialize(bands: DEFAULT_BANDS, sample_rate: DEFAULT_SAMPLE_RATE,
                   window_frames: DEFAULT_WINDOW_FRAMES, retain_frames: DEFAULT_RETAIN_FRAMES)
      @window_frames = window_frames
      @retain_frames = [retain_frames, window_frames].max
      # Sorted, non-overlapping [start_frame, interleaved float32 bytes].
      # Bytes stay packed until a window needs them, so push is O(1) work.
      @segments = []
      @mutex = Mutex.new
      low_hz = LOW_FREQUENCY_HZ
      high_hz = [MAX_FREQUENCY_HZ, sample_rate * NYQUIST_RATIO].min
      log_step = (Math.log(high_hz) - Math.log(low_hz)) / (bands - 1)
      @coefficients = Array.new(bands) do |i|
        frequency_hz = Math.exp(Math.log(low_hz) + (log_step * i))
        2.0 * Math.cos(2.0 * Math::PI * frequency_hz / sample_rate)
      end.freeze
    end

    def push(pcm_bytes, start_frame:)
      return if pcm_bytes.empty?

      end_frame = start_frame + (pcm_bytes.bytesize / FRAME_BYTES)
      @mutex.synchronize do
        # A flush discards buffered audio and later writes reuse its timeline
        # positions, so newer audio replaces anything at or after its start.
        truncate_from(start_frame)
        @segments << [start_frame, pcm_bytes]
        drop_before(end_frame - @retain_frames)
      end
    end

    def reset
      @mutex.synchronize { @segments.clear }
    end

    def levels(at_frame:)
      window = mono_window(at_frame)
      @coefficients.map do |coeff|
        s1 = 0.0
        s2 = 0.0
        window.each do |x|
          s0 = x + (coeff * s1) - s2
          s2 = s1
          s1 = s0
        end
        power = (s1 * s1) + (s2 * s2) - (coeff * s1 * s2)
        magnitude = 2.0 * Math.sqrt(power.abs) / @window_frames
        # perceptual-ish curve so quiet content still moves the bars
        (magnitude**0.5).clamp(0.0, 1.0)
      end
    end

    private

    # Frames never written (before playback starts, after a flush, during an
    # underrun) contribute silence.
    def mono_window(at_frame)
      window_start_frame = at_frame - @window_frames
      mono = Array.new(@window_frames, 0.0)
      @mutex.synchronize { overlapping_slices(window_start_frame, at_frame) }.each do |window_offset_frames, bytes|
        floats = bytes.unpack('e*')
        (floats.size / STEREO_CHANNELS).times do |i|
          mono[window_offset_frames + i] = (floats[i * STEREO_CHANNELS] + floats[(i * STEREO_CHANNELS) + 1]) * 0.5
        end
      end
      mono
    end

    # [offset of the overlap within the window, in frames; the overlap's
    # bytes] for each segment that overlaps the window.
    def overlapping_slices(window_start_frame, window_end_frame)
      @segments.filter_map do |segment_start_frame, bytes|
        segment_end_frame = segment_start_frame + (bytes.bytesize / FRAME_BYTES)
        overlap_start_frame = [segment_start_frame, window_start_frame].max
        overlap_end_frame = [segment_end_frame, window_end_frame].min
        next if overlap_start_frame >= overlap_end_frame

        source_offset_bytes = (overlap_start_frame - segment_start_frame) * FRAME_BYTES
        overlap_size_bytes = (overlap_end_frame - overlap_start_frame) * FRAME_BYTES
        [overlap_start_frame - window_start_frame, bytes.byteslice(source_offset_bytes, overlap_size_bytes)]
      end
    end

    def truncate_from(frame)
      @segments.pop while @segments.any? && @segments.last.first >= frame
      return if @segments.empty?

      segment_start_frame, bytes = @segments.last
      retained_bytes = (frame - segment_start_frame) * FRAME_BYTES
      @segments[-1] = [segment_start_frame, bytes.byteslice(0, retained_bytes)] if retained_bytes < bytes.bytesize
    end

    def drop_before(frame)
      @segments.shift while @segments.any? &&
                            @segments.first.first + (@segments.first.last.bytesize / FRAME_BYTES) <= frame
    end
  end
end
