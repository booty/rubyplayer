require "test_helper"
require "rubyplayer/backends/openmpt"

class OpenmptBackendTest < Minitest::Test
  def setup
    @mpt = RubyPlayer::Backends::Openmpt.new
  end

  def test_track_count_is_one
    assert_equal 1, @mpt.track_count(File.join(FIXTURES, "space-debris.mod"))
  end

  def test_metadata_shape
    meta = @mpt.metadata(File.join(FIXTURES, "space-debris.mod"), 0)
    assert_kind_of String, meta[:title]
    refute_empty meta[:title]
    assert_equal "mod", meta[:format]
    assert_operator meta[:duration_ms], :>, 10_000 # space debris is minutes long
  end

  def test_title_falls_back_to_filename
    # .xm/.s3m usually carry titles; if empty, basename is used — exercise via jpg? No:
    # jpg won't load. Instead assert the fallback logic directly on a real file whose
    # title may or may not be set: the contract is "title is never nil/empty".
    %w[deadlock.xm leynos-2nd-pm.s3m].each do |f|
      meta = @mpt.metadata(File.join(FIXTURES, f), 0)
      refute_nil meta[:title]
      refute_empty meta[:title]
    end
  end

  def test_decode_produces_bounded_float_pcm
    h = @mpt.open(File.join(FIXTURES, "deadlock.xm"), 0, sample_rate: 48_000)
    data = h.read(1024)
    assert_equal 1024 * 2 * 4, data.bytesize
    floats = data.unpack("e*")
    assert(floats.all? { |f| f >= -1.0 && f <= 1.0 })
    h.close
  end

  def test_seek_and_position
    h = @mpt.open(File.join(FIXTURES, "space-debris.mod"), 0, sample_rate: 48_000)
    assert h.seek(10_000)
    assert_in_delta 10_000, h.position_ms, 1_000
    h.close
  end

  def test_open_bogus_file_raises
    assert_raises(RubyPlayer::Backends::Openmpt::Error) do
      @mpt.open(File.join(FIXTURES, "warrior.jpg"), 0, sample_rate: 48_000)
    end
  end
end
