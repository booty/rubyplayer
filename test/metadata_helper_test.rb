require 'test_helper'
require 'rubyplayer/backends/metadata_helper'

class MetadataHelperTest < Minitest::Test
  def test_presence_returns_nil_for_nil_or_empty_strings
    assert_nil RubyPlayer::Backends::MetadataHelper.presence(nil)
    assert_nil RubyPlayer::Backends::MetadataHelper.presence('')
  end

  def test_presence_preserves_non_empty_strings
    value = 'Composer'
    assert_same value, RubyPlayer::Backends::MetadataHelper.presence(value)
  end

  def test_format_extension_returns_lowercase_extension_without_dot
    assert_equal 'mp3', RubyPlayer::Backends::MetadataHelper.format_extension('Song.MP3')
  end

  def test_format_extension_returns_empty_string_without_extension
    assert_equal '', RubyPlayer::Backends::MetadataHelper.format_extension('README')
  end
end
