# frozen_string_literal: true

require 'test_helper'
require 'ffi'
require 'rubyplayer/backends/gme'

# librp_spc ports libgme's SPC pipeline so .spc playback can leave libgme
# without changing a single sample. These tests hold that line on every SPC
# fixture: any difference at all is a regression in rp_spc.cpp's port.
class SnesSpcParityTest < Minitest::Test
  module Lib
    extend FFI::Library

    ffi_lib File.expand_path('../lib/rubyplayer/native/librp_spc.dylib', __dir__)
    attach_function :rp_spc_open, %i[pointer long int], :pointer
    attach_function :rp_spc_close, [:pointer], :void
    attach_function :rp_spc_set_fade, %i[pointer long long], :void
    attach_function :rp_spc_set_ignore_silence, %i[pointer int], :void
    attach_function :rp_spc_play, %i[pointer pointer long], :long
    attach_function :rp_spc_seek, %i[pointer long], :int
  end

  Gme = RubyPlayer::Backends::GmeLib
  RATE = 48_000
  # Matches the engine's default decode chunk: libgme decides fades per call,
  # so both sides must be driven with identical call sizes.
  CHUNK_FRAMES = 16_384
  # gme_set_fade's default fade length.
  GME_FADE_MS = 8_000
  FIXTURE_PATHS = Dir[File.join(FIXTURES, 'spc', '*.spc')].freeze

  def test_fixture_set_is_present
    assert_operator FIXTURE_PATHS.size, :>=, 10
  end

  def test_plain_play_matches_libgme_without_silence_handling
    each_fixture do |path|
      compare(path, seconds: 5, ignore_silence: true)
    end
  end

  # Leading-silence skip and silence detection are on by default for SPC;
  # confusing-melody.spc starts with ~685 ms of silence.
  def test_default_silence_handling_matches_libgme
    each_fixture do |path|
      compare(path, seconds: 5, ignore_silence: false)
    end
  end

  def test_fade_matches_libgme
    each_fixture do |path|
      compare(path, seconds: 2, ignore_silence: false, fade_ms: 1_000, skip_seconds: 1)
    end
  end

  def test_forward_seek_matches_libgme
    each_fixture do |path|
      compare(path, seconds: 2, ignore_silence: true, seek_ms: 30_000)
    end
  end

  private

  def each_fixture(&)
    FIXTURE_PATHS.each(&)
  end

  # Plays both decoders in lockstep and asserts identical int16 output.
  # skip_seconds plays (and still compares) audio before the measured span,
  # so a fade starting partway through is covered.
  def compare(path, seconds:, ignore_silence:, fade_ms: nil, seek_ms: nil, skip_seconds: 0)
    gme = open_gme(path, ignore_silence: ignore_silence, fade_ms: fade_ms)
    ours = open_ours(path, ignore_silence: ignore_silence, fade_ms: fade_ms)
    begin
      if seek_ms
        assert_nil Gme.gme_seek(gme, seek_ms)
        assert_equal 1, Lib.rp_spc_seek(ours, seek_ms)
      end
      gme_buf = FFI::MemoryPointer.new(:short, CHUNK_FRAMES * 2)
      our_buf = FFI::MemoryPointer.new(:float, CHUNK_FRAMES * 2)
      chunks = ((seconds + skip_seconds) * RATE / CHUNK_FRAMES.to_f).ceil
      chunks.times do |chunk|
        Gme.gme_play(gme, CHUNK_FRAMES * 2, gme_buf)
        Lib.rp_spc_play(ours, our_buf, CHUNK_FRAMES)

        assert_same_chunk(path, chunk, gme_buf, our_buf)
      end
    ensure
      Gme.gme_delete(gme)
      Lib.rp_spc_close(ours)
    end
  end

  # Ours is float32 = int16 / 32768 exactly, so converting libgme's int16 the
  # same way makes a byte comparison exact; only on a mismatch do we pay for
  # finding the first differing sample.
  def assert_same_chunk(path, chunk, gme_buf, our_buf)
    expected = gme_buf.read_array_of_int16(CHUNK_FRAMES * 2).map { |sample| sample / 32_768.0 }.pack('e*')
    actual = our_buf.read_bytes(CHUNK_FRAMES * 2 * 4)
    return pass if expected == actual

    index = expected.unpack('e*').zip(actual.unpack('e*')).index { |want, got| want != got }

    flunk "#{File.basename(path)}: chunk #{chunk} differs from libgme at sample #{index}"
  end

  def open_gme(path, ignore_silence:, fade_ms:)
    out = FFI::MemoryPointer.new(:pointer)

    assert_nil Gme.gme_open_file(path, out, RATE)
    emu = out.read_pointer
    Gme.gme_ignore_silence(emu, 1) if ignore_silence

    assert_nil Gme.gme_start_track(emu, 0)
    # A negative start disables fading; libgme otherwise applies its own
    # default (track length, 50 ms) at track start.
    Gme.gme_set_fade(emu, fade_ms || -1)
    emu
  end

  def open_ours(path, ignore_silence:, fade_ms:)
    bytes = File.binread(path)
    handle = Lib.rp_spc_open(FFI::MemoryPointer.from_string(bytes), bytes.bytesize, RATE)

    refute_predicate handle, :null?, "#{File.basename(path)}: rp_spc_open failed"
    Lib.rp_spc_set_ignore_silence(handle, 1) if ignore_silence
    Lib.rp_spc_set_fade(handle, fade_ms || -1, GME_FADE_MS)
    handle
  end
end
