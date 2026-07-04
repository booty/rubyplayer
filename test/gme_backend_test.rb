require "test_helper"
require "rubyplayer/backends/gme"

class GmeBackendTest < Minitest::Test
  def setup
    @gme = RubyPlayer::Backends::Gme.new
  end

  def test_track_count_multitrack_nsf
    assert_operator @gme.track_count(File.join(FIXTURES, "mega-man-2.nsf")), :>, 1
  end

  def test_track_count_single_spc
    assert_equal 1, @gme.track_count(File.join(FIXTURES, "earthbound-megaton-walk.spc"))
  end

  def test_metadata_shape
    meta = @gme.metadata(File.join(FIXTURES, "alisa-dragoon-introduction.vgm"), 0)
    assert_kind_of String, meta[:title]
    refute_empty meta[:title]
    assert_equal "vgm", meta[:format]
    assert_equal 1, meta[:track_number]
  end

  def test_subtune_metadata_has_incremented_track_number
    meta = @gme.metadata(File.join(FIXTURES, "mega-man-2.nsf"), 3)
    assert_equal 4, meta[:track_number]
  end

  def test_decode_produces_bounded_float_pcm
    h = @gme.open(File.join(FIXTURES, "shantae.gbs"), 0, sample_rate: 44_100)
    data = h.read(1024)
    assert_equal 1024 * 2 * 4, data.bytesize # frames * stereo * float32
    floats = data.unpack("e*")
    assert(floats.all? { |f| f >= -1.0 && f <= 1.0 })
    refute(floats.all? { |f| f.zero? }, "expected non-silent audio")
    h.close
  end

  def test_seek_and_position
    h = @gme.open(File.join(FIXTURES, "mega-man-2.nsf"), 1, sample_rate: 44_100)
    h.read(1024)
    assert h.seek(5_000)
    assert_in_delta 5_000, h.position_ms, 500
    h.close
  end

  def test_open_bogus_file_raises
    assert_raises(RubyPlayer::Backends::Gme::Error) do
      @gme.open(File.join(FIXTURES, "warrior.jpg"), 0, sample_rate: 44_100)
    end
  end
end
