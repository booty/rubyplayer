require 'test_helper'
require 'rubyplayer/backends/gme'

class GmeBackendTest < Minitest::Test
  def setup
    @gme = RubyPlayer::Backends::Gme.new
  end

  def test_track_count_multitrack_nsf
    assert_operator @gme.track_count(File.join(FIXTURES, 'nsf', 'mega-man-2.nsf')), :>, 1
  end

  def test_track_count_single_spc
    assert_equal 1, @gme.track_count(File.join(FIXTURES, 'spc/earthbound-megaton-walk.spc'))
  end

  def test_metadata_shape
    meta = @gme.metadata(File.join(FIXTURES, 'alisa-dragoon-introduction.vgm'), 0)

    assert_kind_of String, meta[:title]
    refute_empty meta[:title]
    assert_equal 'vgm', meta[:format]
    assert_equal 1, meta[:track_number]
  end

  def test_metadata_includes_static_hardware_and_timing_for_real_chiptunes
    {
      'alisa-dragoon-introduction.vgm' => ['YM2612', '6 FM'],
      'nsf/mega-man-2.nsf' => ['NES APU', '2 pulse'],
      'shantae.gbs' => ['Game Boy APU', '1 wave'],
      'spc/earthbound-megaton-walk.spc' => ['S-DSP', '8 sample'],
      'hes/air-zonk.hes' => ['HuC6280', '6 wavetable']
    }.each do |file, expected|
      extras = @gme.metadata(File.join(FIXTURES, file), 0).fetch(:extra)

      refute_empty extras.fetch('system')
      assert_includes extras.fetch('sound_chips'), expected.first
      assert_includes extras.fetch('voice_layout'), expected.last
    end
    extras = @gme.metadata(File.join(FIXTURES, 'alisa-dragoon-introduction.vgm'), 0).fetch(:extra)

    assert_match(/\A\d+\.\d+\z/, extras.fetch('vgm_version'))
    assert_includes extras.fetch('chip_clocks'), 'YM2612'
    assert_operator extras.fetch('loop_length_ms').to_i, :>, 0
  end

  def test_each_metadata_opens_once_and_preserves_subtune_metadata
    path = File.join(FIXTURES, 'hes', 'air-zonk.hes')
    expected = Array.new(@gme.track_count(path)) { |i| @gme.metadata(path, i) }
    opens = 0
    original = @gme.method(:open_emu)
    @gme.define_singleton_method(:open_emu) do |*args|
      opens += 1
      original.call(*args)
    end
    entries = @gme.each_metadata(path).to_a

    assert_equal expected, entries.map(&:first)
    assert_equal((0...expected.size).to_a, entries.map { |entry| entry[1] })
    assert(entries.all? { |entry| entry[2] == expected.size })
    assert_equal 1, opens, 'subtunes must share one metadata-only handle'
  end

  def test_subtune_metadata_has_incremented_track_number
    meta = @gme.metadata(File.join(FIXTURES, 'nsf', 'mega-man-2.nsf'), 3)

    assert_equal 4, meta[:track_number]
  end

  # Regression: info[:play_length] is GME's own padded fallback (documented
  # in gme.h as "a default of 150000 (2.5 minutes)" when nothing else is
  # known) -- it used to be read as the track's real duration, so every
  # subtune of a file with no embedded/m3u length data showed exactly 2:30.
  def test_metadata_duration_is_nil_when_gme_has_no_real_length
    meta = @gme.metadata(File.join(FIXTURES, 'nsf', 'mega-man-2.nsf'), 0)

    assert_nil meta[:duration_ms]
  end

  # air-zonk.hes ships with a sibling air-zonk.m3u (a genre convention for
  # NSF/HES rips that don't embed real lengths themselves); loading it gives
  # GME real per-track lengths and titles instead of generic "Track NN"
  # placeholders and the 150000ms fallback.
  def test_metadata_reads_real_length_and_title_from_a_sibling_m3u
    red = @gme.metadata(File.join(FIXTURES, 'hes', 'air-zonk.hes'), 0)

    assert_equal 'Red', red[:title]
    assert_equal 2_000, red[:duration_ms] # m3u: "$42,Red,2,,0" -> 2 seconds

    opening = @gme.metadata(File.join(FIXTURES, 'hes', 'air-zonk.hes'), 1)

    assert_equal 'Opening', opening[:title]
    assert_equal 110_000, opening[:duration_ms] # m3u: "$12,Opening,1:50,,0"
  end

  def test_open_duration_ms_also_uses_the_m3u_length_not_gmes_default
    h = @gme.open(File.join(FIXTURES, 'hes', 'air-zonk.hes'), 1, sample_rate: 44_100)

    assert_equal 110_000, h.duration_ms
    h.close

    h = @gme.open(File.join(FIXTURES, 'nsf', 'mega-man-2.nsf'), 0, sample_rate: 44_100)

    assert_nil h.duration_ms
    h.close
  end

  def test_vgm_voices_can_be_muted
    handle = RubyPlayer::Backends::Gme.new.open(File.join(FIXTURES, 'alisa-dragoon-introduction.vgm'), 0,
                                                sample_rate: 44_100)
    handle.read(44_100)
    handle.mute(0xff)
    2.times { handle.read(16_384) }
    muted = handle.read(16_384).unpack('e*').map(&:abs).max
    handle.mute(0)
    handle.read(16_384)
    unmuted = handle.read(16_384).unpack('e*').map(&:abs).max

    assert_equal 0, handle.mute_mask
    assert_operator muted, :<, 0.001
    assert_operator unmuted, :>, 0.01
  ensure
    handle&.close
  end

  # A muted non-VGM track must not end on libgme's silence detection.
  def test_muting_every_voice_does_not_end_the_track
    handle = RubyPlayer::Backends::Gme.new.open(File.join(FIXTURES, 'nsf', 'mega-man-2.nsf'), 0, sample_rate: 44_100)
    handle.mute(0xff)

    assert_predicate(Array.new(30) { handle.read(16_384) }, :all?)
  ensure
    handle&.close
  end

  def test_decode_produces_bounded_float_pcm
    h = @gme.open(File.join(FIXTURES, 'shantae.gbs'), 0, sample_rate: 44_100)
    data = h.read(1024)

    assert_equal 1024 * RubyPlayer::AudioFormat::BYTES_PER_FRAME, data.bytesize
    floats = data.unpack('e*')

    assert(floats.all? { |f| f >= -1.0 && f <= 1.0 })
    refute(floats.all?(&:zero?), 'expected non-silent audio')
    h.close
  end

  def test_seek_and_position
    h = @gme.open(File.join(FIXTURES, 'nsf', 'mega-man-2.nsf'), 1, sample_rate: 44_100)
    h.read(1024)

    assert h.seek(5_000)
    assert_in_delta 5_000, h.position_ms, 500
    h.close
  end

  def test_open_bogus_file_raises
    assert_raises(RubyPlayer::Backends::Gme::Error) do
      @gme.open(File.join(FIXTURES, 'warrior.jpg'), 0, sample_rate: 44_100)
    end
  end
end
