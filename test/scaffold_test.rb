require 'test_helper'

class ScaffoldTest < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, RubyPlayer::VERSION)
  end

  def test_fixtures_present
    assert_path_exists File.join(FIXTURES, 'space-debris.mod')
    assert_path_exists File.join(FIXTURES, 'mega-man-2.nsf')
  end
end
