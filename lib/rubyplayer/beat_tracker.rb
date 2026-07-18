module RubyPlayer
  # Turns the LevelTap's per-band levels into a small quantized "beat step"
  # for visual effects. Quantization is the load-bearing choice: a continuous
  # envelope would change themed colors every frame and force a full-screen
  # diff repaint at 30fps — steps mean cells only repaint when the envelope
  # crosses a boundary, a few times per beat instead of every frame.
  #
  # UI-thread only, sampled at render cadence; that's plenty of resolution
  # for a visual pulse and avoids touching the decoder thread.
  class BeatTracker
    # Beats live in the low bands; averaging the bottom quarter of the
    # spectrum tracks kick/bass lines without hi-hat noise.
    BASS_FRACTION = 4

    def initialize(steps:, decay:)
      @steps = steps
      @decay = decay
      reset
    end

    def sample(levels)
      return if levels.empty?

      bass = levels.first([levels.size / BASS_FRACTION, 1].max)
      energy = bass.sum / bass.size
      # Rolling peak with slow decay = auto-gain: quiet chiptune channels
      # still pulse full-range instead of pinning near step 0, and the
      # tracker needs no per-format calibration.
      @peak = [@peak * PEAK_DECAY, energy, MIN_PEAK].max
      normalized = energy / @peak
      # Fast attack, configurable release: jump up instantly on a hit, fall
      # smoothly so the pulse reads as a beat rather than flicker.
      @envelope = normalized > @envelope ? normalized : @envelope * @decay
    end

    def step
      (@envelope * (@steps - 1)).round
    end

    def reset
      @envelope = 0.0
      @peak = MIN_PEAK
    end

    # Below this the signal is silence/noise floor; normalizing against it
    # would amplify nothing into a full-brightness pulse.
    MIN_PEAK = 0.01
    PEAK_DECAY = 0.995
  end
end
