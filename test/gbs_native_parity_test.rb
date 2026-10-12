# frozen_string_literal: true

require 'test_helper'
require 'ffi'
require 'fileutils'
require 'tmpdir'
require 'rubyplayer/backends/gme'
require 'rubyplayer/backends/gbs_native_lib'

# librp_gbs builds libgme's own GBS emulator (vendored, plus snapshot hooks),
# so .gbs playback can leave Homebrew libgme without changing a sample. Any
# difference is a regression in the vendored core, its patch, or rp_gbs.cpp
# (the snapshot hooks must not disturb emulation).
class GbsNativeParityTest < Minitest::Test
  Gme = RubyPlayer::Backends::GmeLib
  Lib = RubyPlayer::Backends::GbsNativeLib
  RATE = 48_000
  # The engine's default decode chunk: libgme decides fades per call, so
  # both sides must be driven with identical call sizes.
  CHUNK_FRAMES = 16_384
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
    compare(1, seconds: 2, seek_ms: 20_000)
    compare(1, seconds: 2, seek_ms: 20_000, then_seek_ms: 3_000)
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
    ours = open_ours(0)
    buf = FFI::MemoryPointer.new(:float, CHUNK_FRAMES * 2)
    first = play_snapshot_frames(ours, buf)
    steady = play_snapshot_frames(ours, buf)

    # The first play also gets what libgme emulated ahead while skipping
    # leading silence, starting with the state its first note starts from.
    assert_equal 0, first.first
    # ~341 ms of a 59.7 Hz VBlank driver: one snapshot per call, in order.
    assert_includes 19..22, steady.size
    assert_equal steady.sort, steady
    assert_equal 80, Lib.rp_gbs_snapshot_size
  ensure
    Lib.rp_gbs_close(ours) if ours
  end

  private

  def compare(track, seconds:, ignore_silence: false, fade_ms: nil, seek_ms: nil, then_seek_ms: nil, mute: 0,
              path: PATH, m3u: false)
    options = { ignore_silence: ignore_silence, fade_ms: fade_ms, path: path, m3u: m3u }
    gme = open_gme(track, **options)
    ours = open_ours(track, **options)
    Gme.gme_mute_voices(gme, mute)
    Lib.rp_gbs_mute_voices(ours, mute)
    [seek_ms, then_seek_ms].compact.each do |ms|
      assert_nil Gme.gme_seek(gme, ms)
      assert_equal 1, Lib.rp_gbs_seek(ours, ms)
    end
    gme_buf = FFI::MemoryPointer.new(:short, CHUNK_FRAMES * 2)
    our_buf = FFI::MemoryPointer.new(:float, CHUNK_FRAMES * 2)
    audible = false
    ((seconds * RATE) / CHUNK_FRAMES).ceil.times do |chunk|
      assert_nil Gme.gme_play(gme, CHUNK_FRAMES * 2, gme_buf)
      assert_equal 1, Lib.rp_gbs_play(ours, our_buf, CHUNK_FRAMES)
      expected = gme_buf.read_array_of_int16(CHUNK_FRAMES * 2)
      actual = our_buf.read_array_of_float(CHUNK_FRAMES * 2).map { |sample| (sample * 32_768).round }
      audible ||= expected.any? { |sample| sample.abs > 100 }

      assert_equal expected, actual, "track #{track} chunk #{chunk} differs"
      assert_equal Gme.gme_track_ended(gme), Lib.rp_gbs_track_ended(ours)
    end

    assert audible, "track #{track} was silent; the comparison proves nothing"
  ensure
    Gme.gme_delete(gme) if gme
    Lib.rp_gbs_close(ours) if ours
  end
  # rubocop:enable Metrics/ParameterLists

  def play_snapshot_frames(handle, buf)
    Lib.rp_gbs_play(handle, buf, CHUNK_FRAMES)
    count = Lib.rp_gbs_snapshot_count(handle)
    packed = Lib.rp_gbs_snapshots(handle).read_bytes(count * Lib.rp_gbs_snapshot_size)
    Array.new(count) { |index| packed.unpack1('l<', offset: index * Lib.rp_gbs_snapshot_size) }
  end

  def open_gme(track, ignore_silence: false, fade_ms: nil, path: PATH, m3u: false)
    out = FFI::MemoryPointer.new(:pointer)

    assert_nil Gme.gme_open_file(path, out, RATE)
    emu = out.read_pointer
    assert_nil Gme.gme_load_m3u(emu, path.sub(/\.gbs\z/, '.m3u')) if m3u
    Gme.gme_ignore_silence(emu, 1) if ignore_silence

    assert_nil Gme.gme_start_track(emu, track)
    Gme.gme_set_fade(emu, fade_ms) if fade_ms
    emu
  end

  def open_ours(track, ignore_silence: false, fade_ms: nil, path: PATH, m3u: false)
    handle = Lib.rp_gbs_open(*buffer(File.binread(path)), RATE)

    refute_predicate handle, :null?
    assert_equal 1, Lib.rp_gbs_load_m3u(handle, *buffer(File.binread(path.sub(/\.gbs\z/, '.m3u')))) if m3u
    Lib.rp_gbs_ignore_silence(handle, 1) if ignore_silence

    assert_equal 1, Lib.rp_gbs_start_track(handle, track)
    Lib.rp_gbs_set_fade(handle, fade_ms) if fade_ms
    handle
  end

  def buffer(bytes)
    data = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
    data.put_bytes(0, bytes)
    [data, bytes.bytesize]
  end
end
