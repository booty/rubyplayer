require "test_helper"

class ThemeTest < Minitest::Test
  def test_default_is_first_and_falls_back_for_unknown_ids
    assert_equal :default, RubyPlayer::Theme::ALL_IDS.first
    assert_equal RubyPlayer::Theme::DEFAULT, RubyPlayer::Theme[:unknown_theme]
    assert_equal RubyPlayer::Theme::DEFAULT, RubyPlayer::Theme[nil]
  end

  def test_lookup_accepts_string_or_symbol
    assert_equal RubyPlayer::Theme::THEMES[:neon_cyberpunk], RubyPlayer::Theme["neon_cyberpunk"]
    assert_equal RubyPlayer::Theme::THEMES[:neon_cyberpunk], RubyPlayer::Theme[:neon_cyberpunk]
  end

  def test_every_theme_defines_the_full_semantic_palette
    required_keys = RubyPlayer::Theme::DEFAULT.keys
    RubyPlayer::Theme::ALL.each do |id, theme|
      assert_equal required_keys.sort_by(&:to_s), theme.keys.sort_by(&:to_s),
                   "#{id} is missing or has extra semantic keys"
    end
  end

  def test_named_themes_use_hex_colors_default_uses_ansi_symbols
    color_keys = RubyPlayer::Theme::DEFAULT.keys - %i[name mode]
    RubyPlayer::Theme::THEMES.each_value do |theme|
      color_keys.each { |k| assert_match(/\A#[0-9a-f]{6}\z/, theme[k], "#{theme[:name]} #{k}") }
    end
    color_keys.each do |k|
      value = RubyPlayer::Theme::DEFAULT[k]
      assert(value.nil? || value.is_a?(Symbol), "Default##{k} should be nil or an ANSI symbol")
    end
  end

  # ---- pulse derivation ----

  # neon_cyberpunk: none of its pulse-scoped colors are already white, so
  # brightening must visibly change them (basic_terminal's white
  # border_focus would brighten to itself).
  def base = RubyPlayer::Theme[:neon_cyberpunk]

  def test_step_zero_is_the_base_theme_itself
    assert_same base, RubyPlayer::Theme.pulsed(base, mode: :high, step: 0, steps: 8, shift: 0.3)
  end

  def test_pulse_brightens_only_the_modes_roles
    pulsed = RubyPlayer::Theme.pulsed(base, mode: :low, step: 7, steps: 8, shift: 0.3)

    refute_equal base[:border], pulsed[:border]
    refute_equal base[:border_focus], pulsed[:border_focus]
    # low touches borders only; content colors stay put
    assert_equal base[:selection_bg], pulsed[:selection_bg]
    assert_equal base[:text], pulsed[:text]
  end

  def test_high_mode_reaches_content_colors
    pulsed = RubyPlayer::Theme.pulsed(base, mode: :high, step: 7, steps: 8, shift: 0.3)
    refute_equal base[:selection_bg], pulsed[:selection_bg]
    refute_equal base[:text_muted], pulsed[:text_muted]
  end

  def test_brighten_moves_toward_white_proportionally
    basic = RubyPlayer::Theme[:basic_terminal]
    pulsed = RubyPlayer::Theme.pulsed(basic, mode: :low, step: 7, steps: 8, shift: 0.5)
    # border #5f5f5f (95) at full step, shift 0.5: 95 + (255-95)*0.5 = 175 = #afafaf
    assert_equal "#afafaf", pulsed[:border]
  end

  def test_derived_themes_are_cached_per_step
    a = RubyPlayer::Theme.pulsed(base, mode: :medium, step: 3, steps: 8, shift: 0.3)
    b = RubyPlayer::Theme.pulsed(base, mode: :medium, step: 3, steps: 8, shift: 0.3)
    assert_same a, b
  end

  def test_non_hex_values_pass_through_untouched
    pulsed = RubyPlayer::Theme.pulsed(RubyPlayer::Theme::DEFAULT, mode: :high, step: 7,
                                      steps: 8, shift: 0.3)
    assert_equal RubyPlayer::Theme::DEFAULT[:border], pulsed[:border]
  end

  def test_truecolor_detection
    assert RubyPlayer::Theme.truecolor?(base)
    refute RubyPlayer::Theme.truecolor?(RubyPlayer::Theme::DEFAULT)
  end
end
