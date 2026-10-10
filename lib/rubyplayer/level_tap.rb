# frozen_string_literal: true

require_relative 'audio_format'

module RubyPlayer
  # EQ animation source: per-band magnitudes of the most recent audio, via the
  # Goertzel algorithm at log-spaced frequencies. push() runs on the decoder
  # thread; levels() on the UI thread — guarded by a mutex over a small window.
  class LevelTap
    DEFAULT_BANDS = 16
    DEFAULT_SAMPLE_RATE = 48_000
    DEFAULT_WINDOW_SIZE = 512
    LOW_FREQUENCY_HZ = 60.0
    MAX_FREQUENCY_HZ = 12_000.0
    NYQUIST_RATIO = 0.45
    STEREO_CHANNELS = AudioFormat::CHANNELS
    private_constant :DEFAULT_BANDS, :DEFAULT_SAMPLE_RATE, :DEFAULT_WINDOW_SIZE,
                     :LOW_FREQUENCY_HZ, :MAX_FREQUENCY_HZ, :NYQUIST_RATIO,
                     :STEREO_CHANNELS

    def initialize(bands: DEFAULT_BANDS, sample_rate: DEFAULT_SAMPLE_RATE,
                   window: DEFAULT_WINDOW_SIZE)
      @window = window
      @window_bytes = window * AudioFormat::BYTES_PER_FRAME
      @mono = Array.new(window, 0.0)
      @mutex = Mutex.new
      lo = LOW_FREQUENCY_HZ
      hi = [MAX_FREQUENCY_HZ, sample_rate * NYQUIST_RATIO].min
      step = (Math.log(hi) - Math.log(lo)) / (bands - 1)
      @coefficients = Array.new(bands) do |i|
        frequency = Math.exp(Math.log(lo) + (step * i))
        2.0 * Math.cos(2.0 * Math::PI * frequency / sample_rate)
      end.freeze
    end

    def push(frames_string)
      # Earlier samples cannot survive the rolling window; skip their conversion.
      frames_string = frames_string.byteslice(-@window_bytes, @window_bytes) if frames_string.bytesize > @window_bytes
      floats = frames_string.unpack('e*')
      mono = Array.new(floats.size / STEREO_CHANNELS) do |i|
        offset = i * STEREO_CHANNELS
        (floats[offset] + floats[offset + 1]) * 0.5
      end
      @mutex.synchronize do
        @mono.concat(mono)
        excess = @mono.size - @window
        @mono.shift(excess) if excess.positive?
      end
    end

    def reset
      @mutex.synchronize { @mono.fill(0.0) }
    end

    def levels
      window = @mutex.synchronize { @mono.dup }
      @coefficients.map do |coeff|
        s1 = 0.0
        s2 = 0.0
        window.each do |x|
          s0 = x + (coeff * s1) - s2
          s2 = s1
          s1 = s0
        end
        power = (s1 * s1) + (s2 * s2) - (coeff * s1 * s2)
        magnitude = 2.0 * Math.sqrt(power.abs) / @window
        # perceptual-ish curve so quiet content still moves the bars
        (magnitude**0.5).clamp(0.0, 1.0)
      end
    end
  end
end
