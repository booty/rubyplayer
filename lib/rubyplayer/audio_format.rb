module RubyPlayer
  # Canonical PCM contract shared by decoders, SoX, Ruby framing, and native
  # AudioOutput. Raw PCM carries no header, so every boundary must agree on
  # channel count, sample representation, and frame width before bytes move.
  module AudioFormat
    CHANNELS = 2
    BITS_PER_SAMPLE = 32
    BYTES_PER_SAMPLE = BITS_PER_SAMPLE / 8
    BYTES_PER_FRAME = CHANNELS * BYTES_PER_SAMPLE
    SOX_RAW_ARGS = ["-e", "floating-point", "-b", BITS_PER_SAMPLE.to_s,
                    "-c", CHANNELS.to_s].freeze
  end
end
