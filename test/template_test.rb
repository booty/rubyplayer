require "test_helper"

class TemplateTest < Minitest::Test
  def track(**over)
    RubyPlayer::Track.new(**{ title: "Flash Man", album: "Mega Man 2", artist: "Capcom",
                              track_number: 7, duration_ms: 125_000, rating: 4 }.merge(over))
  end

  def test_basic_render
    t = RubyPlayer::Template.new("{track_number} {title} {duration}")
    assert_equal "07 Flash Man 2:05", t.render(track)
  end

  def test_rating_renders_stars
    t = RubyPlayer::Template.new("{rating}")
    assert_equal "★★★★", t.render(track)
    assert_equal "", t.render(track(rating: nil))
  end

  def test_conditional_artist
    t = RubyPlayer::Template.new("{title} {artist?}")
    assert_equal "Flash Man Capcom", t.render(track, album_artist: "Konami")
    assert_equal "Flash Man", t.render(track, album_artist: "Capcom")
  end

  def test_unknown_field_renders_empty_and_never_evals
    t = RubyPlayer::Template.new("{title} {system('rm -rf /')} {nope}")
    assert_equal "Flash Man", t.render(track)
  end

  def test_nil_fields_collapse_whitespace
    t = RubyPlayer::Template.new("{album} {track_number} {title}")
    assert_equal "Flash Man", t.render(track(album: nil, track_number: nil))
  end

  def test_duration_formatting
    t = RubyPlayer::Template.new("{duration}")
    assert_equal "0:05", t.render(track(duration_ms: 5_400))
    assert_equal "10:00", t.render(track(duration_ms: 600_000))
    assert_equal "", t.render(track(duration_ms: nil))
  end
end
