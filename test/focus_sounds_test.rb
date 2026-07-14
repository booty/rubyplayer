require "test_helper"

class FocusSoundsTest < Minitest::Test
  RECIPES = {
    green: ["synth", "pinknoise", "highpass", "120", "lowpass", "2500",
            "equalizer", "500", "1.0q", "+3", "equalizer", "1000", "1.0q", "+2",
            "tremolo", "0.08", "12", "gain", "-12"],
    rain: ["synth", "pinknoise", "highpass", "300", "lowpass", "7000",
           "equalizer", "1600", "0.7q", "+3", "equalizer", "3500", "1.0q", "+2",
           "tremolo", "0.08", "12", "gain", "-15"],
    fan: ["synth", "brownnoise", "highpass", "45", "lowpass", "1800",
          "equalizer", "120", "0.7q", "+4", "equalizer", "240", "0.8q", "+2",
          "equalizer", "900", "1.0q", "-2", "tremolo", "0.08", "12", "gain", "-11"],
    brown: ["synth", "brownnoise", "highpass", "40", "lowpass", "1000",
            "tremolo", "0.08", "12", "gain", "-12"],
    beach_rain: ["synth", "pinknoise", "highpass", "80", "lowpass", "4500",
                 "equalizer", "180", "0.8q", "+4", "equalizer", "650", "0.9q", "+3",
                 "equalizer", "2500", "1.0q", "-3", "tremolo", "0.08", "45", "reverb",
                 "35", "50", "60", "40", "0", "0", "gain", "-9"],
    beach_rain_dark: ["synth", "brownnoise", "highpass", "45", "lowpass", "3000",
                       "equalizer", "120", "0.8q", "+4", "equalizer", "500", "1.0q", "+2",
                       "equalizer", "1800", "1.0q", "-2", "tremolo", "0.055", "38", "reverb",
                       "30", "45", "55", "35", "0", "0", "gain", "-11"],
  }.freeze

  def test_catalog_has_ordered_titles_and_exact_recipes
    sounds = RubyPlayer::FocusSounds::ALL

    assert_equal ["Green Noise", "Brown Noise", "Rain", "Fan", "Beach Rain", "Beach Rain (Dark)"],
                 sounds.map(&:title)
    assert_equal RECIPES, sounds.to_h { |sound| [sound.id, sound.sox_args] }
  end

  def test_catalog_and_recipe_arguments_are_immutable
    sound = RubyPlayer::FocusSounds::ALL.first

    assert_predicate RubyPlayer::FocusSounds::ALL, :frozen?
    assert_predicate sound, :frozen?
    assert_predicate sound.sox_args, :frozen?
  end
end
