require "ffi"

module RubyPlayer
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
  # holds module-level state). Input format: float32 interleaved stereo, packed
  # with Array#pack("e*").
  class AudioOutput
    BYTES_PER_FRAME = 2 * 4 # stereo float32

    attr_reader :sample_rate

    def initialize(sample_rate: "auto", ring_buffer_ms: 500, null_backend: false, native: RpAudio)
      @native = native
      @write_mutex = Mutex.new
      rate = sample_rate == "auto" ? 0 : Integer(sample_rate)
      code = @native.rp_init(rate, ring_buffer_ms, null_backend ? 1 : 0)
      raise "rp_audio init failed (code #{code})" unless code.zero?
      @sample_rate = @native.rp_sample_rate
    end

    # Returns the number of frames accepted (0 when the buffer is full).
    def write(frames_string)
      unless (frames_string.bytesize % BYTES_PER_FRAME).zero?
        raise ArgumentError, "PCM data must contain complete stereo float32 frames"
      end

      @write_mutex.synchronize do
        frame_count = frames_string.bytesize / BYTES_PER_FRAME
        @ptr = FFI::MemoryPointer.new(:float, frame_count * 2) if @ptr.nil? || @ptr.size < frames_string.bytesize
        @ptr.put_bytes(0, frames_string)
        @native.rp_write(@ptr, frame_count)
      end
    end

    def start = @native.rp_start
    def stop = @native.rp_stop
    def paused=(flag)
      @write_mutex.synchronize { @native.rp_set_paused(flag ? 1 : 0) }
    end
    def writable_frames = @native.rp_writable_frames
    def buffered_frames = @native.rp_buffered_frames
    def frames_played = @native.rp_frames_played
    def flush = @write_mutex.synchronize { @native.rp_flush }
    def close = @write_mutex.synchronize { @native.rp_free }
  end
end
