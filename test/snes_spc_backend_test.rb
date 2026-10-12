# frozen_string_literal: true

require 'test_helper'
require 'minitest/mock'
require 'rubyplayer/backends/registry'
require 'rubyplayer/backends/gme'
require 'rubyplayer/backends/snes_spc'

class SnesSpcBackendTest < Minitest::Test
  SPC = File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc')
  RATE = 48_000

  def setup
    @backend = RubyPlayer::Backends::SnesSpc.new
  end

  def teardown
    @handle&.close
  end

  def test_registry_routes_spc_to_the_native_player_by_default
    registry = RubyPlayer::Backends::Registry.new

    assert_equal :snes_spc, registry.backend_name_for('/x/a.spc')
    assert_equal 'snes_spc', registry.backend_for('/x/a.spc').name
    assert_equal 'gme', registry.backend_for('/x/a.nsf').name
  end

  def test_backends_config_override_restores_libgme_playback
    registry = RubyPlayer::Backends::Registry.new('.spc' => 'gme')

    assert_equal 'gme', registry.backend_for('/x/a.spc').name
  end

  def test_missing_native_library_falls_back_to_libgme
    RubyPlayer::Backends::SnesSpc.stub(:available?, false) do
      registry = RubyPlayer::Backends::Registry.new

      assert_equal 'gme', registry.backend_for('/x/a.spc').name
    end
  end

  # Scanning stays on libgme: tags, lengths, and hardware extras must not change.
  def test_metadata_is_libgmes
    gme = RubyPlayer::Backends::Gme.new

    assert_equal gme.metadata(SPC, 0), @backend.metadata(SPC, 0)
    assert_equal 1, @backend.track_count(SPC)
    assert_equal gme.each_metadata(SPC).to_a, @backend.each_metadata(SPC).to_a
  end

  def test_handle_reads_float32_stereo_with_libgmes_duration
    @handle = @backend.open(SPC, 0, sample_rate: RATE)
    data = @handle.read(4_096)

    assert_equal 4_096 * RubyPlayer::AudioFormat::BYTES_PER_FRAME, data.bytesize
    assert_operator data.unpack('e*').map(&:abs).max, :<=, 1.0
    assert_equal RubyPlayer::Backends::Gme.new.metadata(SPC, 0)[:duration_ms], @handle.duration_ms
  end

  # Same output libgme's handle would give: the backends must be interchangeable.
  def test_handle_output_matches_the_libgme_handle
    gme_handle = RubyPlayer::Backends::Gme.new.open(SPC, 0, sample_rate: RATE)
    @handle = @backend.open(SPC, 0, sample_rate: RATE)

    3.times { assert_equal gme_handle.read(16_384), @handle.read(16_384) }
  ensure
    gme_handle&.close
  end

  def test_seek_position_and_idempotent_close
    @handle = @backend.open(SPC, 0, sample_rate: RATE)

    assert @handle.seek(10_000)
    assert_in_delta 10_000, @handle.position_ms, 5
    @handle.close
    @handle.close

    assert_nil @handle.read(1_024)
    refute @handle.seek(0)
    assert_equal 0, @handle.position_ms
  end

  def test_mute_silences_voices_and_reports_the_mask
    @handle = @backend.open(SPC, 0, sample_rate: RATE)
    @handle.mute(0xff)
    2.times { @handle.read(16_384) }
    data = @handle.read(16_384)

    assert_equal 0xff, @handle.mute_mask
    assert_operator data.unpack('e*').map(&:abs).max, :<, 0.05
  end

  def test_opening_a_non_spc_file_raises
    path = File.join(FIXTURES, 'mega-man-2.nsf')

    assert_raises(RubyPlayer::Backends::SnesSpc::Error) { @backend.open(path, 0, sample_rate: RATE) }
  end
end
