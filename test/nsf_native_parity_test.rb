# frozen_string_literal: true

require 'test_helper'
require 'ffi'
require 'tmpdir'
require 'rubyplayer/backends/gme'
require 'rubyplayer/backends/nsf_native_lib'
require_relative 'support/rip_fixtures'
require_relative 'support/nsf_builder'

# librp_nsf builds libgme's own NSF emulator (vendored, plus snapshot hooks),
# so .nsf playback can leave Homebrew libgme without changing a sample, for
# the 2A03 and every expansion chip. Any difference is a regression in the
# vendored core, its patch, or rp_nsf.cpp (the snapshot hooks, which step the
# APUs' frame counters, must not disturb emulation).
class NsfNativeParityTest < Minitest::Test
  Gme = RubyPlayer::Backends::GmeLib
  Lib = RubyPlayer::Backends::NsfNativeLib
  Rips = TestSupport::RipFixtures
  RATE = 48_000
  # The engine's default decode chunk: libgme decides fades per call, so
  # both sides must be driven with identical call sizes.
  CHUNK_FRAMES = 16_384

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
    compare(:lagrange_point, 0, seconds: 2, seek_ms: 20_000)
    compare(:mega_man_2, 0, seconds: 2, seek_ms: 20_000)
    compare(:metroid, 0, seconds: 2, seek_ms: 3_000)
    compare(:metroid_fds, 0, seconds: 2, seek_ms: 20_000, then_seek_ms: 3_000)
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

  def compare(name, track, seconds:, ignore_silence: false, fade_ms: nil, seek_ms: nil, then_seek_ms: nil, mute: 0,
              m3u: false)
    path = name.is_a?(Symbol) ? Rips.path(name) : name
    gme = open_gme(path, track, ignore_silence: ignore_silence, fade_ms: fade_ms, m3u: m3u)
    ours = open_ours(path, track, ignore_silence: ignore_silence, fade_ms: fade_ms, m3u: m3u)
    Gme.gme_mute_voices(gme, mute)
    Lib.rp_nsf_mute_voices(ours, mute)
    [seek_ms, then_seek_ms].compact.each do |ms|
      assert_nil Gme.gme_seek(gme, ms)
      assert_equal 1, Lib.rp_nsf_seek(ours, ms)
    end
    gme_buf = FFI::MemoryPointer.new(:short, CHUNK_FRAMES * 2)
    our_buf = FFI::MemoryPointer.new(:float, CHUNK_FRAMES * 2)
    audible = false
    ((seconds * RATE) / CHUNK_FRAMES).ceil.times do |chunk|
      assert_nil Gme.gme_play(gme, CHUNK_FRAMES * 2, gme_buf)
      assert_equal 1, Lib.rp_nsf_play(ours, our_buf, CHUNK_FRAMES)
      expected = gme_buf.read_array_of_int16(CHUNK_FRAMES * 2)
      actual = our_buf.read_array_of_float(CHUNK_FRAMES * 2).map { |sample| (sample * 32_768).round }
      audible ||= expected.any? { |sample| sample.abs > 100 }

      assert_equal expected, actual, "#{name} track #{track} chunk #{chunk} differs"
      assert_equal Gme.gme_track_ended(gme), Lib.rp_nsf_track_ended(ours)
    end

    assert audible, "#{name} track #{track} was silent; the comparison proves nothing"
  ensure
    Gme.gme_delete(gme) if gme
    Lib.rp_nsf_close(ours) if ours
  end

  def open_gme(path, track, ignore_silence:, fade_ms:, m3u:)
    out = FFI::MemoryPointer.new(:pointer)

    assert_nil Gme.gme_open_file(path, out, RATE)
    emu = out.read_pointer
    assert_nil Gme.gme_load_m3u(emu, m3u_path(path)) if m3u
    Gme.gme_ignore_silence(emu, 1) if ignore_silence

    assert_nil Gme.gme_start_track(emu, track)
    Gme.gme_set_fade(emu, fade_ms) if fade_ms
    emu
  end

  def open_ours(path, track, ignore_silence:, fade_ms:, m3u:)
    handle = Lib.rp_nsf_open(*buffer(File.binread(path)), RATE)

    refute_predicate handle, :null?
    assert_equal 1, Lib.rp_nsf_load_m3u(handle, *buffer(File.binread(m3u_path(path)))) if m3u
    Lib.rp_nsf_ignore_silence(handle, 1) if ignore_silence

    assert_equal 1, Lib.rp_nsf_start_track(handle, track)
    Lib.rp_nsf_set_fade(handle, fade_ms) if fade_ms
    handle
  end

  def m3u_path(path) = path.sub(/\.nsfe?\z/, '.m3u')

  def buffer(bytes)
    data = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
    data.put_bytes(0, bytes)
    [data, bytes.bytesize]
  end
end
