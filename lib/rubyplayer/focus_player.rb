require_relative "audio_format"

module RubyPlayer
  # Owns SoX process and exposes its raw stdout as a pull-based PCM source.
  # PlaybackEngine calls #read on decoder thread, keeping that thread sole
  # AudioOutput producer; no FFI write can outlive process replacement/teardown.
  class FocusPlayer
    class Error < StandardError; end
    READ_SIZE = 16 * 1024

    def initialize(spawn: Process.method(:spawn), kill: Process.method(:kill),
                   waitpid: Process.method(:waitpid),
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: Kernel.method(:sleep), pipe: IO.method(:pipe))
      @spawn = spawn
      @kill = kill
      @waitpid = waitpid
      @clock = clock
      @sleeper = sleeper
      @pipe = pipe
      clear_state
    end

    def play(sound, sample_rate:)
      stop
      reader, writer = @pipe.call
      # stdout is raw PCM consumed by PlaybackEngine. stdin/stderr use null so
      # child cannot consume TUI keys or paint diagnostics over terminal frame.
      pid = @spawn.call(*command_for(sound, sample_rate), in: File::NULL,
                        out: writer, err: File::NULL)
      # Child owns duplicated write descriptor; parent must close its copy for
      # reader to observe EOF when SoX exits.
      writer.close
      @pid = pid
      @reader = reader
      @current = sound
      @pending = +"".b
      true
    rescue SystemCallError => e
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      message = e.is_a?(Errno::ENOENT) ? "sox executable not found" : "unable to start sox: #{e.message}"
      raise Error, message, cause: e
    end

    # Returns at most requested complete frames. IO#readpartial may split a
    # float or stereo frame anywhere, so incomplete tail remains for next read.
    def read(frame_count)
      return nil unless @reader

      target_bytes = frame_count * AudioFormat::BYTES_PER_FRAME
      complete = take_complete_frames(target_bytes)
      return complete if complete

      # Nonblocking read is essential because this runs on decoder thread; a
      # stalled child must not prevent that thread from receiving stop/shutdown.
      chunk = @reader.read_nonblock(READ_SIZE, exception: false)
      return +"".b if chunk == :wait_readable
      if chunk.nil?
        finish_after_eof
        return nil
      end

      @pending << chunk
      take_complete_frames(target_bytes) || +"".b
    rescue EOFError, IOError
      finish_after_eof
      nil
    end

    def stop
      return false unless @pid

      pid = @pid
      reader = @reader
      begin
        reader&.close unless reader&.closed?
        terminate(pid)
      ensure
        clear_state
      end
      true
    rescue SystemCallError => e
      raise Error, "unable to stop sox: #{e.message}", cause: e
    end

    def playing? = !@pid.nil?
    attr_reader :current

    private

    def command_for(sound, sample_rate)
      # Raw bytes have no header; AudioFormat supplies exact representation
      # expected by native output while runtime sample rate prevents resampling.
      ["sox", "-q", "-n", "-t", "raw", *AudioFormat::SOX_RAW_ARGS,
       "-r", sample_rate.to_s, "-", *sound.sox_args]
    end

    def finish_after_eof
      begin
        pid = @pid
        @reader&.close unless @reader&.closed?
        terminate(pid) if pid
      rescue SystemCallError => e
        raise Error, "unable to stop sox: #{e.message}", cause: e
      ensure
        clear_state
      end
    end

    def take_complete_frames(target_bytes)
      complete_bytes = @pending.bytesize - (@pending.bytesize % AudioFormat::BYTES_PER_FRAME)
      return if complete_bytes.zero?

      byte_count = [complete_bytes, target_bytes].min
      data = @pending.byteslice(0, byte_count)
      @pending = @pending.byteslice(byte_count..) || +"".b
      data
    end

    def clear_state
      @pid = nil
      @reader = nil
      @current = nil
      @pending = +"".b
    end

    def terminate(pid)
      # TERM normally reaps immediately. One-second monotonic deadline handles
      # wedged generators, then KILL guarantees endless SoX cannot outlive app.
      @kill.call("TERM", pid)
      return if reaped?(pid)

      deadline = @clock.call + 1
      until @clock.call >= deadline
        @sleeper.call(0.01)
        return if reaped?(pid)
      end

      @kill.call("KILL", pid)
      @waitpid.call(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def reaped?(pid)
      !@waitpid.call(pid, Process::WNOHANG).nil?
    rescue Errno::ECHILD
      true
    end
  end
end
