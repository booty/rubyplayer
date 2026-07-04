require "ffi"

module RubyPlayer
  module Backends
    module OpenmptLib
      extend FFI::Library
      ffi_lib ["openmpt", "libopenmpt.dylib", "/opt/homebrew/lib/libopenmpt.dylib"]

      attach_function :openmpt_module_create_from_memory2,
                      [:pointer, :size_t, :pointer, :pointer, :pointer, :pointer,
                       :pointer, :pointer, :pointer], :pointer
      attach_function :openmpt_module_destroy, [:pointer], :void
      attach_function :openmpt_module_read_interleaved_float_stereo,
                      [:pointer, :int32, :size_t, :pointer], :size_t, blocking: true
      attach_function :openmpt_module_get_duration_seconds, [:pointer], :double
      attach_function :openmpt_module_set_position_seconds, [:pointer, :double], :double
      attach_function :openmpt_module_get_position_seconds, [:pointer], :double
      attach_function :openmpt_module_get_metadata, [:pointer, :string], :pointer
      attach_function :openmpt_free_string, [:pointer], :void
    end

    class Openmpt
      class Error < StandardError; end

      def name = "openmpt"

      def track_count(_path) = 1 # tracker modules are single-song

      def metadata(path, _subtune_index)
        with_mod(path) do |mod|
          {
            title: presence(read_meta(mod, "title")) || File.basename(path, ".*"),
            album: nil,
            artist: presence(read_meta(mod, "artist")),
            composer: presence(read_meta(mod, "artist")),
            track_number: nil,
            duration_ms: (OpenmptLib.openmpt_module_get_duration_seconds(mod) * 1000).round,
            format: File.extname(path).delete_prefix(".").downcase,
          }
        end
      end

      def open(path, _subtune_index, sample_rate:)
        Handle.new(create_mod(path), sample_rate)
      end

      class Handle
        attr_reader :duration_ms

        def initialize(mod, sample_rate)
          @mod = mod
          @sample_rate = sample_rate
          @duration_ms = (OpenmptLib.openmpt_module_get_duration_seconds(mod) * 1000).round
        end

        # openmpt renders float natively — read_bytes is already our canonical format.
        def read(frames)
          # Guard: after #close, @mod is nil (native module already destroyed).
          # Passing NULL into libopenmpt's read function is undefined behavior
          # and reliably segfaults the whole Ruby process, not just this call.
          return nil if @mod.nil?

          if @buf.nil? || @buf_frames != frames
            @buf = FFI::MemoryPointer.new(:float, frames * 2)
            @buf_frames = frames
          end
          n = OpenmptLib.openmpt_module_read_interleaved_float_stereo(@mod, @sample_rate, frames, @buf)
          return nil if n.zero? # end of module
          @buf.read_bytes(n * 2 * 4)
        end

        # Not an endless method: needs the same use-after-close guard as #read,
        # since a closed handle's @mod is nil and NULL into libopenmpt segfaults.
        def seek(ms)
          return false if @mod.nil?

          OpenmptLib.openmpt_module_set_position_seconds(@mod, ms / 1000.0)
          true
        end

        # Same use-after-close guard as #seek/#read; 0 is a harmless sentinel
        # for "no position" rather than dereferencing a freed native pointer.
        def position_ms
          return 0 if @mod.nil?

          (OpenmptLib.openmpt_module_get_position_seconds(@mod) * 1000).round
        end

        def close
          OpenmptLib.openmpt_module_destroy(@mod) if @mod
          @mod = nil
        end
      end

      private

      def create_mod(path)
        data = File.binread(path)
        ptr = FFI::MemoryPointer.new(:char, data.bytesize)
        ptr.put_bytes(0, data)
        mod = OpenmptLib.openmpt_module_create_from_memory2(
          ptr, data.bytesize, nil, nil, nil, nil, nil, nil, nil
        )
        raise Error, "libopenmpt could not load #{path}" if mod.null?
        mod
      end

      def with_mod(path)
        mod = create_mod(path)
        yield mod
      ensure
        OpenmptLib.openmpt_module_destroy(mod) if mod && !mod.null?
      end

      def read_meta(mod, key)
        ptr = OpenmptLib.openmpt_module_get_metadata(mod, key)
        return nil if ptr.null?
        str = ptr.read_string.dup.force_encoding("UTF-8")
        OpenmptLib.openmpt_free_string(ptr)
        str
      end

      def presence(str) = str.nil? || str.empty? ? nil : str
    end
  end
end
