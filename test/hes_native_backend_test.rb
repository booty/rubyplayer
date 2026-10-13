# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'rubyplayer/backends/registry'
require 'rubyplayer/backends/gme'
require 'rubyplayer/backends/hes_native'
require_relative 'support/rip_fixtures'

class HesNativeBackendTest < Minitest::Test
  Rips = TestSupport::RipFixtures
  RATE = 48_000

  def setup
    @backend = RubyPlayer::Backends::HesNative.new
  end

  def teardown
    @handle&.close
  end

  def test_registry_routes_hes_to_the_native_player_by_default
    registry = RubyPlayer::Backends::Registry.new

    assert_equal :hes_native, registry.backend_name_for('/x/a.hes')
    assert_equal 'hes_native', registry.backend_for('/x/a.hes').name
  end

  def test_backends_config_override_restores_libgme_playback
    assert_equal 'gme', RubyPlayer::Backends::Registry.new('.hes' => 'gme').backend_for('/x/a.hes').name
  end

  def test_missing_native_library_falls_back_to_libgme
    RubyPlayer::Backends::HesNative.stub(:available?, false) do
      assert_equal 'gme', RubyPlayer::Backends::Registry.new.backend_for('/x/a.hes').name
    end
  end

  # Scanning stays on libgme, including the playlist an archived rip ships
  # beside its .hes: track count, titles, and lengths must not change.
  def test_metadata_is_libgmes
    gme = RubyPlayer::Backends::Gme.new
    %i[air_zonk blazing_lazers].each do |name|
      path = Rips.path(name)

      assert_equal gme.track_count(path), @backend.track_count(path)
      assert_equal gme.metadata(path, 1), @backend.metadata(path, 1)
    end
  end

  # Byte for byte what Gme::Handle produces for the playlist's track,
  # through the same handle contract.
  def test_reads_match_the_libgme_handle_for_an_archived_rip
    path = Rips.path(:blazing_lazers)
    gme = RubyPlayer::Backends::Gme.new.open(path, 1, sample_rate: RATE)
    @handle = @backend.open(path, 1, sample_rate: RATE)

    3.times do
      expected = gme.read(4_096)

      refute_nil expected
      assert_equal expected, @handle.read(4_096)
    end
    assert_equal gme.duration_ms, @handle.duration_ms
  ensure
    gme&.close
  end

  def test_reads_record_psg_snapshots
    @handle = @backend.open(Rips.path(:air_zonk), 1, sample_rate: RATE)
    @handle.read(16_384)
    packed, count = @handle.take_snapshots
    snapshots = Array.new(count) { |index| RubyPlayer::Hes::Snapshot.unpack(packed, index) }

    assert_operator count, :>, 5
    assert_equal RubyPlayer::Hes::Snapshot, @handle.snapshot_type
    assert(snapshots.any? { |snapshot| snapshot.playing.positive? })
  end

  # The state heard at the target, then what libgme emulated beyond it.
  def test_capture_now_after_a_seek_starts_at_frame_zero
    @handle = @backend.open(Rips.path(:air_zonk), 1, sample_rate: RATE)

    assert @handle.seek(5_000)
    packed, count = @handle.capture_now
    frames = Array.new(count) { |index| RubyPlayer::Hes::Snapshot.unpack(packed, index).frame }

    assert_equal 0, frames.first
    assert_equal frames.sort, frames
    assert_in_delta 5_000, @handle.position_ms, 1
  end

  # All six voices, bits 0-5, as libgme numbers them. The first read was
  # already emulated (libgme's silence lookahead), as with libgme itself.
  def test_muting_every_voice_silences_the_track_and_keeps_it_alive
    @handle = @backend.open(Rips.path(:air_zonk), 1, sample_rate: RATE)
    @handle.mute(0b11_1111)
    audio = Array.new(10) { @handle.read(16_384) }

    refute_includes audio, nil
    assert(audio.drop(1).join.unpack('e*').all? { |sample| sample.abs < 0.001 })
    assert_equal 0b11_1111, @handle.mute_mask
  end
end
