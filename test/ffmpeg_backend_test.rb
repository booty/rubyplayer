require 'test_helper'
require 'tmpdir'
require 'rubyplayer/backends/ffmpeg'

class FfmpegBackendTest < Minitest::Test
  def tagged_fixture(dir, tags, extension: 'mp3')
    path = File.join(dir, "tagged.#{extension}")
    args = tags.flat_map { |k, v| ['-metadata', "#{k}=#{v}"] }
    system('ffmpeg', '-hide_banner', '-loglevel', 'error',
           '-f', 'lavfi', '-i', 'sine=frequency=440:duration=0.2',
           *args, path, exception: true)
    path
  end

  def test_metadata_extracts_album_artist_year_and_extra_tags
    Dir.mktmpdir do |dir|
      path = tagged_fixture(dir, { 'album_artist' => 'Various Artists',
                                   'date' => '1998-11-20', 'genre' => 'Rock',
                                   'album' => 'Hits', 'title' => 'Song' })
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)

      assert_equal 'Various Artists', meta[:album_artist]
      assert_equal 1998, meta[:year]
      assert_equal 'Rock', meta[:extra]['genre']
      assert_equal '1998-11-20', meta[:extra]['date'] # raw date preserved in extras
      refute_includes meta[:extra].keys, 'title'      # consumed keys excluded
      refute_includes meta[:extra].keys, 'album_artist'
    end
  end

  def test_metadata_preserves_track_totals_and_source_audio_details_across_formats
    codecs = { 'mp3' => 'mp3', 'm4a' => 'aac', 'flac' => 'flac' }
    %w[mp3 m4a flac].each do |extension|
      Dir.mktmpdir do |dir|
        path = tagged_fixture(dir, { 'artist' => 'Artist', 'album' => 'Album',
                                     'track' => '3/12' }, extension: extension)
        meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)

        assert_equal 'Artist', meta[:artist]
        assert_equal 'Album', meta[:album]
        assert_equal 3, meta[:track_number]
        assert_equal '12', meta[:extra]['track_total']
        assert_equal codecs[extension], meta[:extra]['codec']
        assert_equal '44100', meta[:extra]['sample_rate']
        assert_equal '1', meta[:extra]['channels']
        assert_operator meta[:extra]['bit_rate'].to_i, :>, 0
      end
    end
  end

  def test_metadata_understands_separate_vorbis_track_total_tags
    Dir.mktmpdir do |dir|
      path = tagged_fixture(dir, { 'track' => '4', 'TRACKTOTAL' => '14' }, extension: 'flac')
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)

      assert_equal 4, meta[:track_number]
      assert_equal '14', meta[:extra]['track_total']
    end
  end

  # Bug: the metadata_value_limit cap was only applied in extra_tags, so a
  # promoted tag column like title (bloated by a corrupt/oversized frame) was
  # stored uncapped, even though every SELECT * view query hydrates it.
  def test_metadata_caps_oversized_title_tag
    Dir.mktmpdir do |dir|
      long_title = 'x' * 10_000
      path = tagged_fixture(dir, { 'title' => long_title })
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)
      limit = RubyPlayer::DEFAULTS['library']['metadata_value_limit']

      assert_operator meta[:title].bytesize, :<=, limit
      assert_predicate meta[:title], :valid_encoding?
    end
  end

  def test_metadata_year_nil_when_absent_or_implausible
    Dir.mktmpdir do |dir|
      path = tagged_fixture(dir, { 'date' => 'not a date', 'title' => 'Song' })
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)

      assert_nil meta[:year]
    end
  end

  def test_metadata_scrubs_invalid_utf8_and_caps_value_size
    Dir.mktmpdir do |dir|
      long = 'x' * 10_000
      path = tagged_fixture(dir, { 'comment' => long, 'title' => 'Song' })
      meta = RubyPlayer::Backends::Ffmpeg.new.metadata(path, 0)
      limit = RubyPlayer::DEFAULTS['library']['metadata_value_limit']

      assert_operator meta[:extra]['comment'].bytesize, :<=, limit
      # Scrubbing guarantee: every stored value is valid UTF-8 (mislabeled
      # ID3 encodings otherwise crash Ruby string ops far from the scan).
      assert meta[:extra].values.all?(&:valid_encoding?)
    end
  end
end
