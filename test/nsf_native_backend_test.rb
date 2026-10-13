# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'tmpdir'
require 'zlib'
require 'rubyplayer/backends/registry'
require 'rubyplayer/backends/gme'
require 'rubyplayer/backends/nsf_native'
require_relative 'support/rip_fixtures'
require_relative 'support/nsf_builder'

class NsfNativeBackendTest < Minitest::Test
  Rips = TestSupport::RipFixtures
  RATE = 48_000

  def setup
    @backend = RubyPlayer::Backends::NsfNative.new
  end

  def teardown
    @handle&.close
  end

  def test_registry_routes_nsf_and_nsfe_to_the_native_player_by_default
    registry = RubyPlayer::Backends::Registry.new

    %w[/x/a.nsf /x/a.nsfe].each do |path|
      assert_equal :nsf_native, registry.backend_name_for(path)
      assert_equal 'nsf_native', registry.backend_for(path).name
    end
  end

  def test_backends_config_override_restores_libgme_playback
    assert_equal 'gme', RubyPlayer::Backends::Registry.new('.nsf' => 'gme').backend_for('/x/a.nsf').name
  end

  def test_missing_native_library_falls_back_to_libgme
    RubyPlayer::Backends::NsfNative.stub(:available?, false) do
      assert_equal 'gme', RubyPlayer::Backends::Registry.new.backend_for('/x/a.nsf').name
    end
  end

  # Scanning stays on libgme: tags, lengths, and hardware extras must not change.
  def test_metadata_is_libgmes
    gme = RubyPlayer::Backends::Gme.new
    path = Rips.path(:lagrange_point)

    assert_equal gme.metadata(path, 3), @backend.metadata(path, 3)
    assert_equal gme.track_count(path), @backend.track_count(path)
  end

  # Byte for byte what Gme::Handle produces, through the same handle
  # contract, including the m3u's track remapping and length.
  def test_reads_match_the_libgme_handle
    %i[mega_man_2 gimmick].each do |name|
      gme = RubyPlayer::Backends::Gme.new.open(Rips.path(name), 1, sample_rate: RATE)
      @handle = @backend.open(Rips.path(name), 1, sample_rate: RATE)

      3.times do
        expected = gme.read(4_096)

        refute_nil expected
        assert_equal expected, @handle.read(4_096)
      end
      assert_equal gme.duration_ms, @handle.duration_ms
    ensure
      gme&.close
      @handle&.close
    end
  end

  def test_reads_record_chip_snapshots
    @handle = @backend.open(Rips.path(:castlevania_3_japan), 0, sample_rate: RATE)
    @handle.read(16_384)
    packed, count = @handle.take_snapshots
    snapshots = Array.new(count) { |index| RubyPlayer::Nsf::Snapshot.unpack(packed, index) }

    assert_operator count, :>, 5
    assert_equal RubyPlayer::Nsf::Snapshot, @handle.snapshot_type
    assert(snapshots.any? { |snapshot| snapshot.playing.positive? })
    assert(snapshots.all? { |snapshot| snapshot.chip?(:vrc6) && snapshot.voice_count == 8 })
    assert_in_delta 60.1, snapshots.last.driver_hz, 0.01
  end

  def test_pal_rips_run_the_driver_at_50_hz
    @handle = @backend.open(Rips.path(:gimmick_europe), 0, sample_rate: RATE)
    @handle.read(16_384)
    packed, = @handle.take_snapshots
    snapshot = RubyPlayer::Nsf::Snapshot.unpack(packed, 0)

    assert_predicate snapshot, :pal?
    assert_in_delta 50.0, snapshot.driver_hz, 0.05
  end

  def test_capture_now_after_a_seek_starts_at_frame_zero
    @handle = @backend.open(Rips.path(:mega_man_2), 1, sample_rate: RATE)

    assert @handle.seek(5_000)
    packed, count = @handle.capture_now
    frames = Array.new(count) { |index| RubyPlayer::Nsf::Snapshot.unpack(packed, index).frame }

    assert_equal 0, frames.first
    assert_equal frames.sort, frames
    assert_in_delta 5_000, @handle.position_ms, 1
  end

  def test_muting_every_voice_keeps_the_track_alive
    @handle = @backend.open(Rips.path(:lagrange_point), 0, sample_rate: RATE)
    @handle.mute((1 << 11) - 1)

    10.times { refute_nil @handle.read(16_384) }
    assert_equal (1 << 11) - 1, @handle.mute_mask
  end

  # libgme plays gzip-compressed content under an .nsf name.
  def test_gzip_compressed_nsf_content_plays_like_the_plain_file
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'compressed.nsf')
      Zlib::GzipWriter.open(path) { |gzip| gzip.write(File.binread(Rips.path(:castlevania))) }
      plain = @backend.open(Rips.path(:castlevania), 0, sample_rate: RATE)
      @handle = @backend.open(path, 0, sample_rate: RATE)

      assert_equal plain.read(16_384), @handle.read(16_384)
    ensure
      plain&.close
    end
  end

  # NSFe is a chunked container for the same code: libgme loads it through
  # its own type, which the native player picks by the file's tag.
  def test_nsfe_files_play_and_record_like_nsf
    Dir.mktmpdir do |dir|
      nsf = TestSupport::NsfBuilder.short_note_nsf.b
      info = [0x8000, 0x8000, 0x800a, 0, 0, 1, 0].pack('S<S<S<CCCC')
      chunk = ->(id, data) { [data.bytesize].pack('L<') + id + data }
      path = File.join(dir, 'short.nsfe')
      File.binwrite(path, "NSFE#{chunk.call('INFO', info)}#{chunk.call('DATA', nsf.byteslice(0x80..))}" \
                          "#{chunk.call('NEND', '')}")
      @handle = @backend.open(path, 0, sample_rate: RATE)
      audio = Array.new(4) { @handle.read(16_384) }.join
      packed, count = @handle.take_snapshots

      assert_operator audio.unpack('e*').map(&:abs).max, :>, 0.01
      assert_operator count, :>, 0
      assert_equal 5, RubyPlayer::Nsf::Snapshot.unpack(packed, 0).voice_count
    end
  end

  def test_garbage_is_rejected
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'bad.nsf')
      File.binwrite(path, 'not an nsf file at all' * 10)

      assert_raises(StandardError) { @backend.open(path, 0, sample_rate: RATE) }
    end
  end
end
