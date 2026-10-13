# frozen_string_literal: true

require 'test_helper'
require 'fileutils'
require 'tmpdir'
require 'rubyplayer/backends/gbs_native_lib'
require_relative 'support/native_parity'

# librp_gbs builds libgme's own GBS emulator (vendored, plus snapshot hooks),
# so .gbs playback can leave Homebrew libgme without changing a sample. Any
# difference is a regression in the vendored core, its patch, or rp_gbs.cpp
# (the snapshot hooks must not disturb emulation).
class GbsNativeParityTest < Minitest::Test
  include TestSupport::NativeParity

  Lib = RubyPlayer::Backends::GbsNativeLib
  NATIVE = Native.new(lib: Lib, prefix: 'rp_gbs')
  PATH = File.join(FIXTURES, 'shantae.gbs')
  TRACKS = [0, 1, 5, 12, 20].freeze

  def test_default_silence_handling_matches_libgme
    TRACKS.each { |track| compare(track, seconds: 6) }
  end

  def test_ignoring_silence_matches_libgme
    TRACKS.each { |track| compare(track, seconds: 4, ignore_silence: true) }
  end

  def test_fade_matches_libgme
    TRACKS.first(2).each { |track| compare(track, seconds: 3, fade_ms: 1_000) }
  end

  def test_seeks_match_libgme
    compare(1, seconds: 2, seeks: [20_000])
    compare(1, seconds: 2, seeks: [20_000, 3_000])
  end

  # A sibling m3u remaps track numbers and supplies lengths; both players
  # must load it to play the same tune for the same index.
  def test_m3u_playlist_matches_libgme
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'shantae.gbs')
      FileUtils.cp(PATH, path)
      File.write(File.join(dir, 'shantae.m3u'), "shantae.gbs::GBS,9,Ninth,0:45,,5\nshantae.gbs::GBS,3,Third,1:00\n")
      [0, 1].each { |track| compare(track, seconds: 2, path: path, m3u: true) }
    end
  end

  def test_muting_matches_libgme
    compare(0, seconds: 3, mute: 0b0101)
  end

  def test_snapshots_follow_the_music_driver
    native_handle = open_native(NATIVE, PATH, 0)
    native_output = FFI::MemoryPointer.new(:float, CHUNK_FRAMES * 2)
    first = play_snapshot_frames(native_handle, native_output)
    steady = play_snapshot_frames(native_handle, native_output)

    # The first play also gets what libgme emulated ahead while skipping
    # leading silence, starting with the state its first note starts from.
    assert_equal 0, first.first
    # ~341 ms of a 59.7 Hz VBlank driver (20 calls): the registers each call
    # that writes leaves, plus envelope and length changes, in order.
    assert_operator steady.size, :>=, 10
    assert_equal steady.sort, steady
    assert_equal 80, Lib.rp_gbs_snapshot_size
  ensure
    Lib.rp_gbs_close(native_handle) if native_handle
  end

  private

  def compare(track, seconds:, path: PATH, m3u: false, **)
    assert_matches_libgme(NATIVE, path, track, seconds: seconds, label: "track #{track}",
                                               m3u_path: (path.sub(/\.gbs\z/, '.m3u') if m3u), **)
  end

  def play_snapshot_frames(handle, output)
    Lib.rp_gbs_play(handle, output, CHUNK_FRAMES)
    count = Lib.rp_gbs_snapshot_count(handle)
    packed = Lib.rp_gbs_snapshots(handle).read_bytes(count * Lib.rp_gbs_snapshot_size)
    Array.new(count) { |index| packed.unpack1('l<', offset: index * Lib.rp_gbs_snapshot_size) }
  end
end
