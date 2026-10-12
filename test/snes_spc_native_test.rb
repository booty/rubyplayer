# frozen_string_literal: true

require 'test_helper'
require 'ffi'

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
  end

  RATE = 48_000
  SPC = File.join(FIXTURES, 'spc', 'earthbound-megaton-walk.spc')

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

  private

  def open_spc
    bytes = File.binread(SPC)
    pointer = FFI::MemoryPointer.from_string(bytes)
    handle = Lib.rp_spc_open(pointer, bytes.bytesize, RATE)
    (@handles ||= []) << handle unless handle.null?
    handle
  end
end
