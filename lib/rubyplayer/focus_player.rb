require_relative "audio_format"

module RubyPlayer
  # Runs SoX as an endless PCM generator, then feeds its stdout through the
  # same AudioOutput used by normal tracks. Routing SoX through Ruby instead of
  # letting `play` open the sound device gives the app one audio owner and lets
  # track playback, Focus playback, pause, flush, and shutdown coordinate.
  class FocusPlayer
    class Error < StandardError; end
    # Pipe reads are batched for efficiency. This is a byte count, not a promise
    # that IO will return exactly this many bytes.
    READ_SIZE = 16 * 1024
    def initialize(audio:, spawn: Process.method(:spawn), kill: Process.method(:kill),
                   waitpid: Process.method(:waitpid),
                   clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                   sleeper: Kernel.method(:sleep), pipe: IO.method(:pipe))
      @audio = audio
      @spawn = spawn
      @kill = kill
      @waitpid = waitpid
      @clock = clock
      @sleeper = sleeper
      @pipe = pipe
      @pid = nil
      @current = nil
      @reader = nil
      @thread = nil
      @stopping_pid = nil
    end

    def play(sound)
      # Focus sounds replace each other; they never overlap or enter the queue.
      stop
      reader, writer = @pipe.call
      # SoX writes raw PCM to our pipe. stdin/stderr go to /dev/null so a child
      # process cannot consume keystrokes or paint diagnostics over the TUI.
      pid = @spawn.call(*command_for(sound), in: File::NULL, out: writer,
                        err: File::NULL)
      # The child owns its duplicated write descriptor. Closing the parent's
      # copy is what allows the reader to observe EOF when SoX exits.
      writer.close
      @reader = reader
      @pid = pid
      @current = sound
      @audio.paused = false
      @thread = Thread.new { drain(reader, pid) }
      true
    rescue SystemCallError => e
      # Process setup can fail after both pipe descriptors exist. Close both
      # parent copies before translating OS-specific errors into this class's
      # stable API; callers should not need to understand Process internals.
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      message = e.is_a?(Errno::ENOENT) ? "sox executable not found" : "unable to start sox: #{e.message}"
      raise Error, message, cause: e
    end

    def stop
      pid = @pid
      reader = @reader
      thread = @thread
      return false unless pid

      # Closing the pipe makes drain see IOError. Mark this as intentional so
      # that thread does not compete with us to terminate/reap the same child.
      @stopping_pid = pid

      # Keep ownership fields intact until teardown finishes. If termination
      # raises, the ensure blocks still join the PCM writer before AudioOutput
      # can be freed; clearing state early previously left an orphan writer
      # calling rp_write against a null C ring buffer.
      begin
        reader&.close unless reader&.closed?
        terminate(pid)
      ensure
        begin
          thread&.join
          @audio.paused = true
          @audio.flush
        ensure
          @pid = nil
          @current = nil
          @reader = nil
          @thread = nil
          @stopping_pid = nil
        end
      end
      true
    rescue SystemCallError => e
      # Teardown above has already joined the writer and cleared ownership.
      # Expose one FocusPlayer error type while retaining errno as the cause.
      raise Error, "unable to stop sox: #{e.message}", cause: e
    end

    def playing? = !@pid.nil?
    attr_reader :current

    private

    def command_for(sound)
      # `-t raw` needs every format detail because raw bytes carry no header.
      # These values deliberately match AudioOutput's stereo float32 contract
      # and actual device sample rate, avoiding conversion in Ruby or C.
      ["sox", "-q", "-n", "-t", "raw", *AudioFormat::SOX_RAW_ARGS,
       "-r", @audio.sample_rate.to_s, "-", *sound.sox_args]
    end

    def drain(reader, pid)
      # IO#readpartial may split anywhere, including in the middle of an
      # 8-byte frame. Preserve that tail and only send complete frames to FFI.
      pending = +"".b
      loop do
        pending << reader.readpartial(READ_SIZE)
        pending = write_complete_frames(pending)
      end
    rescue EOFError, IOError
      nil
    ensure
      reader.close unless reader.closed?
      finish_after_drain(pid, reader)
    end

    def finish_after_drain(pid, reader)
      # EOF without #stop means SoX died or closed stdout. It can no longer
      # produce audio, so terminate/reap any lingering process and retire this
      # generation. Identity checks prevent an old drain thread from clearing a
      # replacement sound that has already installed a different pipe or PID.
      return if @stopping_pid == pid
      return unless @pid == pid && @reader.equal?(reader)

      terminate(pid)
      return unless @pid == pid && @reader.equal?(reader)

      @audio.paused = true
      @audio.flush
      @pid = nil
      @current = nil
      @reader = nil
      @thread = nil
    rescue SystemCallError
      # Explicit #stop remains available to retry cleanup. Worker-thread errors
      # cannot be raised usefully to UI and must not kill process-wide playback.
      nil
    end

    def write_complete_frames(data)
      byte_count = data.bytesize - (data.bytesize % AudioFormat::BYTES_PER_FRAME)
      return data if byte_count.zero?

      write_fully(data.byteslice(0, byte_count))
      data.byteslice(byte_count..) || +"".b
    end

    def write_fully(data)
      remaining = data
      until remaining.empty?
        frames = @audio.write(remaining)
        if frames.zero?
          # A full ring is normal backpressure: CoreAudio must consume some
          # frames before the producer can continue. Sleep avoids busy-spinning.
          @sleeper.call(0.005)
          next
        end
        remaining = remaining.byteslice(frames * AudioFormat::BYTES_PER_FRAME..)
      end
    end

    def terminate(pid)
      # Give SoX a chance to exit and be reaped cleanly. Escalate only if it
      # ignores TERM, preventing an endless generator from surviving the app.
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
