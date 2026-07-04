require "test_helper"

class ScaffoldTest < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, RubyPlayer::VERSION)
  end

  def test_fixtures_present
    assert File.exist?(File.join(FIXTURES, "space-debris.mod"))
    assert File.exist?(File.join(FIXTURES, "mega-man-2.nsf"))
  end
end
