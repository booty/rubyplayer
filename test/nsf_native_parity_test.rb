# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require 'rubyplayer/backends/nsf_native_lib'
require_relative 'support/native_parity'
require_relative 'support/rip_fixtures'
require_relative 'support/nsf_builder'

# librp_nsf builds libgme's own NSF emulator (vendored, plus snapshot hooks),
# so .nsf playback can leave Homebrew libgme without changing a sample, for
# the 2A03 and every expansion chip. Any difference is a regression in the
# vendored core, its patch, or rp_nsf.cpp (the snapshot hooks, which step the
# APUs' frame counters, must not disturb emulation).
class NsfNativeParityTest < Minitest::Test
  include TestSupport::NativeParity

  Lib = RubyPlayer::Backends::NsfNativeLib
  NATIVE = Native.new(lib: Lib, prefix: 'rp_nsf')
  Rips = TestSupport::RipFixtures

  def test_every_nsf_rip_matches_libgme
    Rips.names('nsf').each { |name| compare(name, 0, seconds: 4) }
  end

  def test_later_tracks_match_libgme
    %i[mega_man_2 castlevania_3_japan lagrange_point metroid_fds erika_to_satoru gimmick just_breed].each do |name|
      compare(name, 3, seconds: 3)
    end
  end

  def test_ignoring_silence_matches_libgme
    %i[mega_man_2 gimmick].each { |name| compare(name, 1, seconds: 3, ignore_silence: true) }
  end

  def test_fade_matches_libgme
    compare(:castlevania, 1, seconds: 3, fade_ms: 1_000)
  end

  # Long seeks skip with every voice muted, when libgme's triangle keeps its
  # phase in a way that depends on how its time is split: the snapshot hooks
  # must leave those splits alone.
  def test_seeks_match_libgme
    compare(:lagrange_point, 0, seconds: 2, seeks: [20_000])
    compare(:mega_man_2, 0, seconds: 2, seeks: [20_000])
    compare(:metroid, 0, seconds: 2, seeks: [3_000])
    compare(:metroid_fds, 0, seconds: 2, seeks: [20_000, 3_000])
  end

  def test_muting_matches_libgme
    compare(:castlevania_3_japan, 0, seconds: 3, mute: 0b1010_0101)
    compare(:metroid, 0, seconds: 3, mute: 0b0_0100)
    compare(:erika_to_satoru, 0, seconds: 3, mute: 0b1_1111_0000_0000)
  end

  # Zipped rips carry a sibling m3u that remaps track numbers; both players
  # must load it to play the same tune for the same index.
  def test_m3u_playlists_match_libgme
    [0, 2].each { |track| compare(:gimmick, track, seconds: 2, m3u: true) }
  end

  # The hand-built NSFs drive the FDS envelope and MMC5 PCM, whose
  # snapshots are simulated between writes.
  def test_built_nsfs_match_libgme
    Dir.mktmpdir do |dir|
      %i[short_note_nsf mmc5_pcm_nsf fds_fade_nsf].each do |builder|
        path = File.join(dir, "#{builder}.nsf")
        File.binwrite(path, TestSupport::NsfBuilder.public_send(builder))
        compare(path, 0, seconds: 2)
      end
    end
  end

  def test_snapshot_layout_matches_the_ruby_record
    assert_equal 380, Lib.rp_nsf_snapshot_size
  end

  private

  def compare(name, track, seconds:, m3u: false, **)
    path = name.is_a?(Symbol) ? Rips.path(name) : name

    assert_matches_libgme(NATIVE, path, track, seconds: seconds, label: "#{File.basename(path.to_s)} track #{track}",
                                               m3u_path: (path.sub(/\.nsfe?\z/, '.m3u') if m3u), **)
  end
end
