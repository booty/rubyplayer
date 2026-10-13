# frozen_string_literal: true

require 'ffi'
require 'rubyplayer/backends/gme'

module TestSupport
  # Lockstep audio comparison of a native player built on vendored libgme
  # (librp_gbs, librp_nsf) against Homebrew libgme, loaded independently as
  # the reference. Both sides get identical call sizes: libgme decides fades
  # per call. Include it and call assert_matches_libgme.
  module NativeParity
    Reference = RubyPlayer::Backends::GmeLib
    RATE = 48_000
    # The engine's default decode chunk.
    CHUNK_FRAMES = 16_384

    # A native player's C API: `<prefix>_open`, `_play`, ... on `lib`.
    Native = Data.define(:lib, :prefix) do
      def call(function, *) = lib.public_send(:"#{prefix}_#{function}", *)
    end

    # Plays `seconds` of `track` on both players after the same mutes and
    # seeks, and fails at the first differing sample. Also fails when the
    # reference stays silent: identical silence proves nothing.
    def assert_matches_libgme(native, path, track, seconds:, label:, ignore_silence: false, fade_ms: nil, seeks: [],
                              mute: 0, m3u_path: nil)
      options = { ignore_silence: ignore_silence, fade_ms: fade_ms, m3u_path: m3u_path }
      reference_handle = open_reference(path, track, **options)
      native_handle = open_native(native, path, track, **options)
      Reference.gme_mute_voices(reference_handle, mute)
      native.call(:mute_voices, native_handle, mute)
      seeks.each do |ms|
        assert_nil Reference.gme_seek(reference_handle, ms)
        assert_equal 1, native.call(:seek, native_handle, ms)
      end
      play_in_lockstep(native, reference_handle, native_handle, seconds: seconds, label: label)
    ensure
      Reference.gme_delete(reference_handle) if reference_handle
      native.call(:close, native_handle) if native_handle
    end

    def open_reference(path, track, ignore_silence: false, fade_ms: nil, m3u_path: nil)
      out = FFI::MemoryPointer.new(:pointer)

      assert_nil Reference.gme_open_file(path, out, RATE)
      handle = out.read_pointer
      assert_nil Reference.gme_load_m3u(handle, m3u_path) if m3u_path
      Reference.gme_ignore_silence(handle, 1) if ignore_silence

      assert_nil Reference.gme_start_track(handle, track)
      Reference.gme_set_fade(handle, fade_ms) if fade_ms
      handle
    end

    def open_native(native, path, track, ignore_silence: false, fade_ms: nil, m3u_path: nil)
      handle = native.call(:open, *native_buffer(File.binread(path)), RATE)

      refute_predicate handle, :null?
      assert_equal 1, native.call(:load_m3u, handle, *native_buffer(File.binread(m3u_path))) if m3u_path
      native.call(:ignore_silence, handle, 1) if ignore_silence

      assert_equal 1, native.call(:start_track, handle, track)
      native.call(:set_fade, handle, fade_ms) if fade_ms
      handle
    end

    private

    def play_in_lockstep(native, reference_handle, native_handle, seconds:, label:)
      reference_buffer = FFI::MemoryPointer.new(:short, CHUNK_FRAMES * 2)
      native_output = FFI::MemoryPointer.new(:float, CHUNK_FRAMES * 2)
      audible = false
      ((seconds * RATE) / CHUNK_FRAMES).ceil.times do |chunk|
        assert_nil Reference.gme_play(reference_handle, CHUNK_FRAMES * 2, reference_buffer)
        assert_equal 1, native.call(:play, native_handle, native_output, CHUNK_FRAMES)
        expected = reference_buffer.read_array_of_int16(CHUNK_FRAMES * 2)
        audible ||= expected.any? { |sample| sample.abs > 100 }
        assert_same_samples(expected, native_output, "#{label} chunk #{chunk}")
        assert_equal Reference.gme_track_ended(reference_handle), native.call(:track_ended, native_handle)
      end

      assert audible, "#{label} was silent; the comparison proves nothing"
    end

    # The native player returns libgme's int16 samples scaled to floats.
    # Reports only the first difference: a full diff of 32,768 samples is
    # unreadable.
    def assert_same_samples(expected, native_output, label)
      actual = native_output.read_array_of_float(CHUNK_FRAMES * 2).map { |sample| (sample * 32_768).round }
      return pass if expected == actual

      index = expected.zip(actual).index { |want, got| want != got }
      flunk "#{label} differs from libgme at sample #{index}: #{expected[index]} vs #{actual[index]}"
    end

    def native_buffer(bytes)
      data = FFI::MemoryPointer.new(:uchar, bytes.bytesize)
      data.put_bytes(0, bytes)
      [data, bytes.bytesize]
    end
  end
end
