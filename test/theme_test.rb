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
end
