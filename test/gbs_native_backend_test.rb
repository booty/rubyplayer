# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'fileutils'
require 'tmpdir'
require 'zlib'
require 'rubyplayer/backends/registry'
require 'rubyplayer/backends/gme'
require 'rubyplayer/backends/gbs_native'

class GbsNativeBackendTest < Minitest::Test
  GBS = File.join(FIXTURES, 'shantae.gbs')
  RATE = 48_000

  def setup
    @backend = RubyPlayer::Backends::GbsNative.new
  end

  def teardown
    @handle&.close
  end

  def test_registry_routes_gbs_to_the_native_player_by_default
    registry = RubyPlayer::Backends::Registry.new

    assert_equal :gbs_native, registry.backend_name_for('/x/a.gbs')
    assert_equal 'gbs_native', registry.backend_for('/x/a.gbs').name
  end

  def test_backends_config_override_restores_libgme_playback
    assert_equal 'gme', RubyPlayer::Backends::Registry.new('.gbs' => 'gme').backend_for('/x/a.gbs').name
  end

  def test_missing_native_library_falls_back_to_libgme
    RubyPlayer::Backends::GbsNative.stub(:available?, false) do
      assert_equal 'gme', RubyPlayer::Backends::Registry.new.backend_for('/x/a.gbs').name
    end
  end

  # Scanning stays on libgme: tags, lengths, and hardware extras must not change.
  def test_metadata_is_libgmes
    gme = RubyPlayer::Backends::Gme.new

    assert_equal gme.metadata(GBS, 3), @backend.metadata(GBS, 3)
    assert_equal gme.track_count(GBS), @backend.track_count(GBS)
  end

  # Byte for byte what Gme::Handle produces, through the same handle contract.
  def test_reads_match_the_libgme_handle
    gme = RubyPlayer::Backends::Gme.new.open(GBS, 1, sample_rate: RATE)
    @handle = @backend.open(GBS, 1, sample_rate: RATE)

    3.times do
      expected = gme.read(4_096)

      refute_nil expected
      assert_equal expected, @handle.read(4_096)
    end
    assert_equal gme.duration_ms, @handle.duration_ms
  ensure
    gme&.close
  end

  def test_reads_record_apu_snapshots
    @handle = @backend.open(GBS, 0, sample_rate: RATE)
    @handle.read(16_384)
    packed, count = @handle.take_snapshots
    snapshots = Array.new(count) { |index| RubyPlayer::Gbs::Snapshot.unpack(packed, index) }

    assert_operator count, :>, 5
    assert_equal RubyPlayer::Gbs::Snapshot, @handle.snapshot_record
    assert(snapshots.any? { |snapshot| snapshot.playing.positive? })
    assert_in_delta 59.73, snapshots.last.driver_hz, 0.01
  end

  # The state heard at the target, then what libgme emulated beyond it.
  def test_capture_now_after_a_seek_starts_at_frame_zero
    @handle = @backend.open(GBS, 0, sample_rate: RATE)

    assert @handle.seek(5_000)
    packed, count = @handle.capture_now
    frames = Array.new(count) { |index| RubyPlayer::Gbs::Snapshot.unpack(packed, index).frame }

    assert_equal 0, frames.first
    assert_equal frames.sort, frames
    assert_in_delta 5_000, @handle.position_ms, 1
  end

  def test_sibling_m3u_remaps_tracks_like_libgme
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'game.gbs')
      FileUtils.cp(GBS, path)
      File.write(File.join(dir, 'game.m3u'), "game.gbs::GBS,9,Ninth,0:45,,5\n")
      gme = RubyPlayer::Backends::Gme.new.open(path, 0, sample_rate: RATE)
      @handle = @backend.open(path, 0, sample_rate: RATE)

      assert_equal 45_000, @handle.duration_ms
      2.times { assert_equal gme.read(4_096), @handle.read(4_096) }
    ensure
      gme&.close
    end
  end

  def test_muting_a_voice_silences_it_and_keeps_the_track_alive
    @handle = @backend.open(GBS, 0, sample_rate: RATE)
    @handle.mute(0b1111)

    20.times { refute_nil @handle.read(16_384) }
    assert_equal 0b1111, @handle.mute_mask
  end

  # Regression: libgme plays gzip-compressed content under a .gbs name, so
  # such files scanned fine but failed to open once playback moved here.
  def test_gzip_compressed_gbs_content_plays_like_the_plain_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'compressed.gbs')
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(File.binread(GBS)) }
      plain = @backend.open(GBS, 1, sample_rate: RATE)
      @handle = @backend.open(path, 1, sample_rate: RATE)

      expected = plain.read(16_384)

      refute_nil expected
      assert_equal expected, @handle.read(16_384)
    ensure
      plain&.close
    end
  end

  def test_oversized_compressed_content_is_refused
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'huge.gbs')
      Zlib::GzipWriter.open(path) { |gzip| gzip.write("\0" * (17 * 1024 * 1024)) }

      assert_raises(RubyPlayer::Backends::GbsNative::Error) { @backend.open(path, 0, sample_rate: RATE) }
    end
  end

  def test_garbage_is_rejected
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'bad.gbs')
      File.binwrite(path, 'not a gbs file at all' * 10)

      assert_raises(StandardError) { @backend.open(path, 0, sample_rate: RATE) }
    end
  end
end
