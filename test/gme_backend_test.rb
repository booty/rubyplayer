require 'test_helper'
require 'rubyplayer/backends/gme'
require_relative 'support/rip_fixtures'
require 'tmpdir'
require 'fileutils'

class GmeBackendTest < Minitest::Test
  Rips = TestSupport::RipFixtures
  # sound_chips and voice_layout fragments per rip format.
  HES_HARDWARE = ['HuC6280', '6 wavetable'].freeze
  NSF_HARDWARE = ['NES APU', '2 pulse'].freeze

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
    rips = Rips.names('hes').to_h { |name| [Rips.path(name), HES_HARDWARE] }
    Rips.names('nsf').each { |name| rips[Rips.path(name)] = NSF_HARDWARE }
    # Expansion chips add to the NES APU's own voices.
    { castlevania_3_japan: 'VRC6', lagrange_point: 'VRC7', metroid_fds: 'FDS', just_breed: 'MMC5',
      erika_to_satoru: 'N163', rolling_thunder_japan: 'N163', gimmick: 'S5B' }.each do |name, chip|
      rips[Rips.path(name)] = ["NES APU + #{chip}", 'expansion voices']
    end
    {
      'alisa-dragoon-introduction.vgm' => ['YM2612', '6 FM'],
      'shantae.gbs' => ['Game Boy APU', '1 wave'],
      'spc/earthbound-megaton-walk.spc' => ['S-DSP', '8 sample']
    }.transform_keys { |file| File.join(FIXTURES, file) }.merge(rips).each do |path, expected|
      extras = @gme.metadata(path, 0).fetch(:extra)

      refute_empty extras.fetch('system'), path
      assert_includes extras.fetch('sound_chips'), expected.first, path
      assert_includes extras.fetch('voice_layout'), expected.last, path
    end
    extras = @gme.metadata(File.join(FIXTURES, 'alisa-dragoon-introduction.vgm'), 0).fetch(:extra)

    assert_match(/\A\d+\.\d+\z/, extras.fetch('vgm_version'))
    assert_includes extras.fetch('chip_clocks'), 'YM2612'
    assert_operator extras.fetch('loop_length_ms').to_i, :>, 0
  end

  def test_each_metadata_opens_once_and_preserves_subtune_metadata
    path = Rips.path(:dungeon_explorer)
    expected = Array.new(@gme.track_count(path)) { |i| @gme.metadata(path, i) }
    opens = 0
    original = @gme.method(:open_emu)
    @gme.define_singleton_method(:open_emu) do |*args, **kwargs|
      opens += 1
      original.call(*args, **kwargs)
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
    assert_equal 150_000, meta[:play_length_ms]
    assert_equal 'default', meta[:duration_source]
  end

  def test_metadata_exposes_loop_based_playback_length_without_claiming_a_duration
    meta = @gme.metadata(File.join(FIXTURES, 'alisa-dragoon-introduction.vgm'), 0)

    assert_nil meta[:duration_ms]
    assert_equal 29_215, meta[:play_length_ms]
    assert_equal 'loop_policy', meta[:duration_source]
  end

  def test_title_only_m3u_does_not_claim_an_embedded_duration
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'song.spc')
      FileUtils.cp(File.join(FIXTURES, 'spc/earthbound-megaton-walk.spc'), path)
      File.write(File.join(dir, 'song.m3u'), "song.spc::SPC,0,Renamed\n")

      meta = @gme.metadata(path, 0)

      assert_equal 'Renamed', meta[:title]
      assert_equal 24_000, meta[:duration_ms]
      assert_equal 'file', meta[:duration_source]
    end
  end

  def test_repeated_title_only_m3u_entries_keep_file_duration_provenance
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'song.spc')
      FileUtils.cp(File.join(FIXTURES, 'spc/earthbound-megaton-walk.spc'), path)
      File.write(
        File.join(dir, 'song.m3u'),
        "song.spc::SPC,0,First\nsong.spc::SPC,0,Second\n"
      )

      entries = @gme.each_metadata(path).to_a.map(&:first)

      assert_equal %w[First Second], entries.map { |meta| meta[:title] }
      assert_equal [24_000, 24_000], entries.map { |meta| meta[:duration_ms] }
      assert_equal %w[file file], entries.map { |meta| meta[:duration_source] }
    end
  end

  def test_filename_only_m3u_entry_keeps_later_duration_provenance_aligned
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'song.spc')
      FileUtils.cp(File.join(FIXTURES, 'spc/earthbound-megaton-walk.spc'), path)
      File.write(
        File.join(dir, 'song.m3u'),
        "song.spc\nsong.spc::SPC,0,Timed,0:50\n"
      )

      entries = @gme.each_metadata(path).to_a.map(&:first)

      assert_equal ['Megaton Walk', 'Timed'], entries.map { |meta| meta[:title] }
      assert_equal [24_000, 50_000], entries.map { |meta| meta[:duration_ms] }
      assert_equal %w[file m3u], entries.map { |meta| meta[:duration_source] }
    end
  end

  def test_m3u_duration_provenance_is_tracked_per_entry
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'game.hes')
      FileUtils.cp(File.join(FIXTURES, 'hes/air-zonk.hes'), path)
      File.write(
        File.join(dir, 'game.m3u'),
        "game.hes::HES,$42,Title only\ngame.hes::HES,$43,Timed,0:50\n"
      )

      title_only = @gme.metadata(path, 0)
      timed = @gme.metadata(path, 1)

      assert_nil title_only[:duration_ms]
      assert_equal 'default', title_only[:duration_source]
      assert_equal 50_000, timed[:duration_ms]
      assert_equal 'm3u', timed[:duration_source]
    end
  end

  # Every HES rip, and Lagrange Point, ships with a sibling .m3u (a genre
  # convention for NSF/HES rips that don't embed real lengths themselves);
  # loading it gives GME real per-track lengths, titles, and album tags
  # instead of generic "Track NN" placeholders and the 150000ms fallback.
  # Lengths are the m3u's, whether or not it also names a loop ("41,36,10":
  # 41 s long, loops at 36 s).
  def test_metadata_reads_real_length_and_title_from_a_sibling_m3u
    {
      air_zonk: ['Air Zonk', 21, [['Red', 2_000], ['Opening', 110_000]]],
      alien_crush: ['Alien Crush', 17, [['Title', 41_000], ['Lunar Eclipse', 50_000]]],
      blazing_lazers: ['Blazing Lazers', 20, [['Opening', 55_000], ['Thunder Blaze [Area 1]', 38_000]]],
      dungeon_explorer: ['Dungeon Explorer', 21, [['Title', 91_000], ['Opening', 16_000]]],
      lagrange_point: ['Lagrange Point', 31, [['Theme of Isis', 104_409], ['Find Shutolte', 115_553]]]
    }.each do |name, (album, count, tracks)|
      path = Rips.path(name)

      assert_equal count, @gme.track_count(path), name
      tracks.each_with_index do |(title, duration_ms), index|
        meta = @gme.metadata(path, index)

        assert_equal [album, title, duration_ms], meta.values_at(:album, :title, :duration_ms), name
        assert_equal duration_ms, meta[:play_length_ms], name
        assert_equal 'm3u', meta[:duration_source], name
      end
    end
  end

  # NSF rips without a playlist get libgme's generic titles and no length.
  def test_nsf_rips_without_an_m3u_have_no_real_lengths
    %i[mega_man_2 castlevania silver_surfer castlevania_3_japan].each do |name|
      meta = @gme.metadata(Rips.path(name), 1)

      assert_equal ['Track 02', nil], meta.values_at(:title, :duration_ms), name
    end
  end

  # Expansion audio (VRC6 pulses and sawtooth, VRC7 FM) is libgme's to play.
  def test_every_nsf_rip_plays_audibly
    Rips.names('nsf').each do |name|
      handle = @gme.open(Rips.path(name), 0, sample_rate: 44_100)
      peak = handle.read(2 * 44_100).unpack('e*').map(&:abs).max

      assert_operator peak, :>, 0.1, name
    ensure
      handle&.close
    end
  end

  def test_open_duration_ms_also_uses_the_m3u_length_not_gmes_default
    h = @gme.open(Rips.path(:alien_crush), 1, sample_rate: 44_100)

    assert_equal 50_000, h.duration_ms
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
