# frozen_string_literal: true

require 'test_helper'
require 'rubyplayer/backends/hes_native_lib'
require_relative 'support/native_parity'
require_relative 'support/rip_fixtures'

# librp_hes builds libgme's own HES emulator (vendored, plus snapshot hooks),
# so .hes playback can leave Homebrew libgme without changing a sample. Any
# difference is a regression in the vendored core, its patch, or rp_hes.cpp
# (the snapshot hooks must not disturb emulation).
class HesNativeParityTest < Minitest::Test
  include TestSupport::NativeParity

  Lib = RubyPlayer::Backends::HesNativeLib
  NATIVE = Native.new(lib: Lib, prefix: 'rp_hes')
  Rips = TestSupport::RipFixtures

  # Every rip ships a playlist naming its audible tracks, as players load it.
  def test_every_hes_rip_matches_libgme
    Rips.names('hes').each { |name| compare(name, 0, seconds: 4) }
  end

  def test_later_tracks_match_libgme
    Rips.names('hes').each { |name| compare(name, 2, seconds: 3) }
  end

  # Without the playlist, track numbers are the file's own subtunes.
  def test_raw_subtunes_match_libgme
    compare(:air_zonk, 1, seconds: 3, m3u: false)
  end

  def test_ignoring_silence_matches_libgme
    %i[air_zonk blazing_lazers].each { |name| compare(name, 1, seconds: 3, ignore_silence: true) }
  end

  def test_fade_matches_libgme
    compare(:dungeon_explorer, 0, seconds: 3, fade_ms: 1_000)
  end

  def test_seeks_match_libgme
    compare(:air_zonk, 1, seconds: 2, seeks: [20_000])
    compare(:blazing_lazers, 0, seconds: 2, seeks: [10_000, 3_000])
  end

  # Voice bits 0-3 are the wave voices, 4-5 the noise-capable Multi voices.
  def test_muting_matches_libgme
    compare(:air_zonk, 0, seconds: 3, mute: 0b00_0001)
    compare(:alien_crush, 0, seconds: 3, mute: 0b01_0000)
    compare(:blazing_lazers, 0, seconds: 3, mute: 0b10_1010)
  end

  private

  def compare(name, track, seconds:, m3u: true, **)
    path = Rips.path(name)

    assert_matches_libgme(NATIVE, path, track, seconds: seconds, label: "#{File.basename(path)} track #{track}",
                                               m3u_path: (path.sub(/\.hes\z/, '.m3u') if m3u), **)
  end
end
