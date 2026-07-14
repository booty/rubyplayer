require "test_helper"

class TrackFormatterTest < Minitest::Test
  def track(**overrides)
    RubyPlayer::Track.new(**{
      title: "Flash Man", album: "Mega Man 2", artist: "Capcom",
      track_number: 7, duration_ms: 125_000, rating: 4
    }.merge(overrides))
  end

  def test_helpers_render_styled_conditional_fragments
    formatter = lambda do |item, fmt|
      fmt.line(
        fmt.number(item.track_number, fg: :yellow),
        fmt.text(item.title, bold: true, underline: true),
        (fmt.text(item.artist, italic: true) unless item.artist == fmt.album_artist),
        fmt.duration(item.duration_ms, fg: :text_muted),
        fmt.stars(item.rating, fg: "#ffaa00", dim: true)
      )
    end

    segments = RubyPlayer::TrackFormatter.render(
      formatter, track, album_artist: "Capcom", star_glyph: "★"
    )

    assert_equal "07 Flash Man 2:05 ★★★★", segments.map { |segment| segment[:text] }.join
    title = segments.find { |segment| segment[:text] == "Flash Man" }
    stars = segments.find { |segment| segment[:text] == "★★★★" }
    assert title[:bold]
    assert title[:underline]
    assert stars[:dim]
    assert_equal "#ffaa00", stars[:fg]
    refute_includes segments.map { |segment| segment[:text] }, "Capcom"
  end

  def test_line_flattens_arrays_and_omits_nil_and_empty_values
    formatter = lambda do |_item, fmt|
      fmt.line(["A", nil, [fmt.text(""), fmt.text("B")]], separator: " / ")
    end

    segments = RubyPlayer::TrackFormatter.render(formatter, track)

    assert_equal "A / B", segments.map { |segment| segment[:text] }.join
  end

  def test_formatter_may_return_a_string_or_single_fragment
    assert_equal "plain", RubyPlayer::TrackFormatter.render(
      ->(_item, _fmt) { "plain" }, track
    ).first[:text]
    assert_equal "styled", RubyPlayer::TrackFormatter.render(
      ->(_item, fmt) { fmt.text("styled", italic: true) }, track
    ).first[:text]
  end

  def test_nil_helpers_render_nothing
    formatter = ->(_item, fmt) { fmt.line(fmt.number(nil), fmt.duration(nil), fmt.stars(nil)) }

    assert_empty RubyPlayer::TrackFormatter.render(formatter, track)
  end

  def test_unknown_style_key_is_rejected
    error = assert_raises(RubyPlayer::ConfigError) do
      RubyPlayer::TrackFormatter.render(
        ->(_item, fmt) { fmt.text("x", sparkle: true) }, track
      )
    end

    assert_includes error.message, "sparkle"
  end

  def test_unknown_color_and_malformed_hex_are_rejected
    [:chartreuseish, "#12345g"].each do |color|
      error = assert_raises(RubyPlayer::ConfigError) do
        RubyPlayer::TrackFormatter.render(
          ->(_item, fmt) { fmt.text("x", fg: color) }, track
        )
      end
      assert_includes error.message, color.inspect
    end
  end

  def test_unsupported_return_value_is_rejected
    error = assert_raises(RubyPlayer::ConfigError) do
      RubyPlayer::TrackFormatter.render(->(_item, _fmt) { 42 }, track)
    end

    assert_includes error.message, "Integer"
  end
end
