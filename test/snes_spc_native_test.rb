# frozen_string_literal: true

require 'test_helper'
require 'ffi'
require 'rubyplayer/backends/gme'

# Exercises librp_spc's C API directly; the Ruby backend comes later.
class SnesSpcNativeTest < Minitest::Test
  module Lib
    extend FFI::Library

    ffi_lib File.expand_path('../lib/rubyplayer/native/librp_spc.dylib', __dir__)
    attach_function :rp_spc_open, %i[pointer long int], :pointer
    attach_function :rp_spc_close, [:pointer], :void
    attach_function :rp_spc_set_fade, %i[pointer long long], :void
    attach_function :rp_spc_play, %i[pointer pointer long], :long
    attach_function :rp_spc_track_ended, [:pointer], :int
    attach_function :rp_spc_seek, %i[pointer long], :int
    attach_function :rp_spc_tell_ms, [:pointer], :long
    attach_function :rp_spc_set_ignore_silence, %i[pointer int], :void
    attach_function :rp_spc_mute_voices, %i[pointer int], :void
  end

  module GmeMute
    extend FFI::Library

    ffi_lib RubyPlayer::RuntimeDependencies::GME_LIBRARY_CANDIDATES
    attach_function :gme_mute_voices, %i[pointer int], :void
  end

  RATE = 48_000
  SPC = File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc')
  CONFUSING_MELODY = File.join(FIXTURES, 'spc', 'confusing-melody.spc')
  LONGEST_PLAY_MS = 60_000

  def teardown
    @handles&.each { |handle| Lib.rp_spc_close(handle) }
  end

  def test_opens_spc_data_and_rejects_other_bytes
    refute_predicate open_spc, :null?

    junk = Random.new(1).bytes(0x10200)
    pointer = FFI::MemoryPointer.from_string(junk)

    assert_predicate Lib.rp_spc_open(pointer, junk.bytesize, RATE), :null?
    assert_predicate Lib.rp_spc_open(FFI::Pointer::NULL, 0, RATE), :null?
  end

  def test_play_fills_every_requested_frame_with_audible_float_audio
    handle = open_spc
    frames = 4_096
    out = FFI::MemoryPointer.new(:float, frames * 2)
    loudest = 0.0
    played = Array.new(5 * RATE / frames) do
      written = Lib.rp_spc_play(handle, out, frames)
      loudest = [loudest, out.read_array_of_float(frames * 2).map(&:abs).max].max
      written
    end

    assert_equal [frames], played.uniq
    assert_operator loudest, :>, 0.01
    assert_operator loudest, :<=, 1.0
  end

  def test_seek_moves_the_reported_position
    handle = open_spc

    assert_equal 1, Lib.rp_spc_seek(handle, 30_000)
    assert_in_delta 30_000, Lib.rp_spc_tell_ms(handle), 5
    assert_equal 1, Lib.rp_spc_seek(handle, 2_000)
    assert_in_delta 2_000, Lib.rp_spc_tell_ms(handle), 5
  end

  # libgme's fade halves gain in steps until it drops below 1/256, which takes
  # just under the requested fade length.
  def test_fade_ends_the_track_shortly_after_the_fade_length
    handle = open_spc
    Lib.rp_spc_set_fade(handle, 1_000, 1_000)
    out = FFI::MemoryPointer.new(:float, 1_024 * 2)
    ended_ms = nil
    400.times do
      Lib.rp_spc_play(handle, out, 1_024)
      next unless Lib.rp_spc_track_ended(handle) == 1

      ended_ms = Lib.rp_spc_tell_ms(handle)
      break
    end

    refute_nil ended_ms, 'track never ended'
    assert_operator ended_ms, :>, 1_500
    assert_operator ended_ms, :<, 2_200
  end

  # confusing-melody.spc opens with ~685 ms of silence; like libgme, playback
  # skips it unless silence handling is disabled.
  def test_leading_silence_is_skipped_unless_ignored
    skipped = open_spc(CONFUSING_MELODY)
    kept = open_spc(CONFUSING_MELODY)
    Lib.rp_spc_set_ignore_silence(kept, 1)

    assert_operator first_audible_ms(skipped), :<, 50
    assert_operator first_audible_ms(kept), :>, 600
  end

  # libgme ends a track after 6 s of silence, found by emulating ahead of the
  # output, so the end lands well before 6 s of *output*. Ours must end at the
  # same output position.
  def test_silence_ends_the_track_where_libgme_does
    ours = open_spc
    Lib.rp_spc_set_fade(ours, -1, 0)
    Lib.rp_spc_mute_voices(ours, 0xff)
    gme = RubyPlayer::Backends::Gme.new.open(SPC, 0, sample_rate: RATE)
    emu = gme.instance_variable_get(:@emu)
    RubyPlayer::Backends::GmeLib.gme_set_fade(emu, -1)
    GmeMute.gme_mute_voices(emu, 0xff)

    our_end_ms = play_until_ended(ours)
    gme_end_ms = gme_play_until_ended(gme)

    assert_operator our_end_ms, :<, 6_000
    assert_equal gme_end_ms, our_end_ms
  ensure
    gme&.close
  end

  private

  def first_audible_ms(handle)
    frames = 4_096
    out = FFI::MemoryPointer.new(:float, frames * 2)
    40.times do |chunk|
      Lib.rp_spc_play(handle, out, frames)
      index = out.read_array_of_float(frames * 2).index { |sample| (sample * 32_768).abs > 8 }
      return ((chunk * frames) + (index / 2)) * 1_000.0 / RATE if index
    end

    flunk 'no audible sample in the first ~3 s'
  end

  # Returns the position (ms) at which the track ended.
  def play_until_ended(handle)
    out = FFI::MemoryPointer.new(:float, 4_096 * 2)
    while Lib.rp_spc_track_ended(handle).zero? && Lib.rp_spc_tell_ms(handle) < LONGEST_PLAY_MS
      Lib.rp_spc_play(handle, out, 4_096)
    end
    Lib.rp_spc_tell_ms(handle)
  end

  def gme_play_until_ended(handle)
    nil until handle.read(4_096).nil? || handle.position_ms >= LONGEST_PLAY_MS
    handle.position_ms
  end

  def open_spc(path = SPC)
    bytes = File.binread(path)
    pointer = FFI::MemoryPointer.from_string(bytes)
    handle = Lib.rp_spc_open(pointer, bytes.bytesize, RATE)
    (@handles ||= []) << handle unless handle.null?
    handle
  end
end
