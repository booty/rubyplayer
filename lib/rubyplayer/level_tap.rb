module RubyPlayer
  # EQ animation source: per-band magnitudes of the most recent audio, via the
  # Goertzel algorithm at log-spaced frequencies. push() runs on the decoder
  # thread; levels() on the UI thread — guarded by a mutex over a small window.
  class LevelTap
    def initialize(bands: 16, sample_rate: 48_000, window: 512)
      @bands = bands
      @rate = sample_rate
      @window = window
      @mono = Array.new(window, 0.0)
      @mutex = Mutex.new
      lo = 60.0
      hi = [12_000.0, sample_rate * 0.45].min
      step = (Math.log(hi) - Math.log(lo)) / (bands - 1)
      @freqs = Array.new(bands) { |i| Math.exp(Math.log(lo) + step * i) }
    end

    def push(frames_string)
      floats = frames_string.unpack("e*")
      mono = Array.new(floats.size / 2) { |i| (floats[i * 2] + floats[i * 2 + 1]) * 0.5 }
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
      @freqs.map do |freq|
        coeff = 2.0 * Math.cos(2.0 * Math::PI * freq / @rate)
        s1 = 0.0
        s2 = 0.0
        window.each do |x|
          s0 = x + coeff * s1 - s2
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
