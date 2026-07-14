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
    # SoX is configured for stereo float32: two channels * four bytes each.
    BYTES_PER_FRAME = 8

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
    end

    def play(sound)
      # Focus sounds replace each other; they never overlap or enter the queue.
      stop
      reader, writer = @pipe.call
      # SoX writes raw PCM to our pipe. stdin/stderr go to /dev/null so a child
      # process cannot consume keystrokes or paint diagnostics over the TUI.
      @pid = @spawn.call(*command_for(sound), in: File::NULL, out: writer,
                         err: File::NULL)
      # The child owns its duplicated write descriptor. Closing the parent's
      # copy is what allows the reader to observe EOF when SoX exits.
      writer.close
      @reader = reader
      @current = sound
      @audio.paused = false
      @thread = Thread.new { drain(reader) }
      true
    rescue Errno::ENOENT
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      raise Error, "sox executable not found"
    end

    def stop
      pid = @pid
      reader = @reader
      thread = @thread
      return false unless pid

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
        end
      end
      true
    end

    def playing? = !@pid.nil?
    attr_reader :current

    private

    def command_for(sound)
      # `-t raw` needs every format detail because raw bytes carry no header.
      # These values deliberately match AudioOutput's stereo float32 contract
      # and actual device sample rate, avoiding conversion in Ruby or C.
      ["sox", "-q", "-n", "-t", "raw", "-e", "floating-point", "-b", "32",
       "-c", "2", "-r", @audio.sample_rate.to_s, "-", *sound.sox_args.drop(1)]
    end

    def drain(reader)
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
    end

    def write_complete_frames(data)
      byte_count = data.bytesize - (data.bytesize % BYTES_PER_FRAME)
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
        remaining = remaining.byteslice(frames * BYTES_PER_FRAME..)
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
