module RubyPlayer
  # Focus sounds are recipes rather than library Tracks: no file, duration, or
  # queue identity exists. Arguments are stored as an array (not a shell string)
  # so Process.spawn passes them directly to SoX without shell parsing.
  FocusSound = Struct.new(:id, :title, :sox_args, keyword_init: true)

  module FocusSounds
    # Recipes contain effects only. FocusPlayer owns input/output format flags,
    # keeping catalog entries independent from process plumbing and avoiding a
    # hidden positional rule such as "the first argument must be dropped."
    ALL = [
      FocusSound.new(
        id: :green, title: "Green Noise",
        sox_args: ["synth", "pinknoise", "highpass", "120", "lowpass", "2500",
                   "equalizer", "500", "1.0q", "+3", "equalizer", "1000", "1.0q", "+2",
                   "tremolo", "0.08", "12", "gain", "-12"].freeze
      ).freeze,
      FocusSound.new(
        id: :brown, title: "Brown Noise",
        sox_args: ["synth", "brownnoise", "highpass", "40", "lowpass", "1000",
                   "tremolo", "0.08", "12", "gain", "-12"].freeze
      ).freeze,
      FocusSound.new(
        id: :rain, title: "Rain",
        sox_args: ["synth", "pinknoise", "highpass", "300", "lowpass", "7000",
                   "equalizer", "1600", "0.7q", "+3", "equalizer", "3500", "1.0q", "+2",
                   "tremolo", "0.08", "12", "gain", "-15"].freeze
      ).freeze,
      FocusSound.new(
        id: :fan, title: "Fan",
        sox_args: ["synth", "brownnoise", "highpass", "45", "lowpass", "1800",
                   "equalizer", "120", "0.7q", "+4", "equalizer", "240", "0.8q", "+2",
                   "equalizer", "900", "1.0q", "-2", "tremolo", "0.08", "12", "gain", "-11"].freeze
      ).freeze,
      FocusSound.new(
        id: :beach_rain, title: "Beach Rain",
        sox_args: ["synth", "pinknoise", "highpass", "80", "lowpass", "4500",
                   "equalizer", "180", "0.8q", "+4", "equalizer", "650", "0.9q", "+3",
                   "equalizer", "2500", "1.0q", "-3", "tremolo", "0.08", "45", "reverb",
                   "35", "50", "60", "40", "0", "0", "gain", "-9"].freeze
      ).freeze,
      FocusSound.new(
        id: :beach_rain_dark, title: "Beach Rain (Dark)",
        sox_args: ["synth", "brownnoise", "highpass", "45", "lowpass", "3000",
                   "equalizer", "120", "0.8q", "+4", "equalizer", "500", "1.0q", "+2",
                   "equalizer", "1800", "1.0q", "-2", "tremolo", "0.055", "38", "reverb",
                   "30", "45", "55", "35", "0", "0", "gain", "-11"].freeze
      ).freeze,
    ].freeze
  end
end
