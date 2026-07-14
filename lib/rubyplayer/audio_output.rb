require "ffi"

module RubyPlayer
  # FFI turns these Ruby method calls into calls to functions exported by the
  # bundled C library. The arrays describe each function's C argument types;
  # the final symbol is its return type. `blocking: true` releases Ruby's GVL
  # while C copies samples into the ring buffer, so other Ruby threads may run.
  module RpAudio
    extend FFI::Library
    ffi_lib File.expand_path("native/librp_audio.dylib", __dir__)
    attach_function :rp_init, [:uint, :uint, :int], :int
    attach_function :rp_sample_rate, [], :uint
    attach_function :rp_start, [], :int
    attach_function :rp_stop, [], :int
    attach_function :rp_set_paused, [:int], :void
    attach_function :rp_write, [:pointer, :uint], :uint, blocking: true
    attach_function :rp_writable_frames, [], :uint
    attach_function :rp_buffered_frames, [], :uint
    attach_function :rp_frames_played, [], :uint64
    attach_function :rp_flush, [], :void
    attach_function :rp_free, [], :void
  end

  # Playback device + C-side ring buffer. ONE instance per process (the C shim
  # holds module-level state). A ring buffer lets producers write audio ahead
  # while CoreAudio consumes it at a fixed real-time pace. Input format is
  # float32 interleaved stereo: left float, right float, repeat.
  class AudioOutput
    BYTES_PER_FRAME = 2 * 4 # stereo float32

    attr_reader :sample_rate

    def initialize(sample_rate: "auto", ring_buffer_ms: 500, null_backend: false, native: RpAudio)
      @native = native
      # Normal track decoding and Focus playback use different Ruby threads,
      # but the C ring buffer has one producer and this object reuses one native
      # pointer. Serialize handoffs so neither thread can mutate either resource
      # while the other is inside FFI.
      @write_mutex = Mutex.new
      @closed = false
      rate = sample_rate == "auto" ? 0 : Integer(sample_rate)
      code = @native.rp_init(rate, ring_buffer_ms, null_backend ? 1 : 0)
      raise "rp_audio init failed (code #{code})" unless code.zero?
      @sample_rate = @native.rp_sample_rate
    end

    # Returns frames accepted, which may be fewer than supplied when the ring is
    # full. A frame is one simultaneous stereo sample: two 4-byte floats.
    def write(frames_string)
      # Dividing a partial frame would round down the allocation while
      # put_bytes still copied every byte, allowing an out-of-bounds native
      # write. Reject malformed input before crossing the FFI boundary.
      unless (frames_string.bytesize % BYTES_PER_FRAME).zero?
        raise ArgumentError, "PCM data must contain complete stereo float32 frames"
      end

      @write_mutex.synchronize do
        # Ruby owns lifecycle knowledge, so reject stale producer threads here
        # instead of letting them cross FFI into storage already freed by C.
        raise IOError, "audio output is closed" if @closed

        frame_count = frames_string.bytesize / BYTES_PER_FRAME
        # FFI::MemoryPointer owns C-addressable memory. Reuse the largest one
        # allocated so the hot audio loop does not malloc on every chunk.
        @ptr = FFI::MemoryPointer.new(:float, frame_count * 2) if @ptr.nil? || @ptr.size < frames_string.bytesize
        @ptr.put_bytes(0, frames_string)
        @native.rp_write(@ptr, frame_count)
      end
    end

    def start = @native.rp_start
    def stop = @native.rp_stop
    # Pause/flush/free alter state shared with writes. They use the same mutex
    # so teardown cannot free the C ring while a producer is still writing it.
    def paused=(flag)
      @write_mutex.synchronize { @native.rp_set_paused(flag ? 1 : 0) }
    end
    def writable_frames = @native.rp_writable_frames
    def buffered_frames = @native.rp_buffered_frames
    def frames_played = @native.rp_frames_played
    def flush = @write_mutex.synchronize { @native.rp_flush }
    def close
      @write_mutex.synchronize do
        return false if @closed

        # Mark closed before freeing: even if native teardown raises, retrying a
        # write against partially dismantled device state would be unsafe.
        @closed = true
        @native.rp_free
        true
      end
    end
  end
end
