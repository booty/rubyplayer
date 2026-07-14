module RubyPlayer
  class FocusPlayer
    class Error < StandardError; end
    READ_SIZE = 16 * 1024
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
      stop
      reader, writer = @pipe.call
      @pid = @spawn.call(*command_for(sound), in: File::NULL, out: writer,
                         err: File::NULL)
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
      ["sox", "-q", "-n", "-t", "raw", "-e", "floating-point", "-b", "32",
       "-c", "2", "-r", @audio.sample_rate.to_s, "-", *sound.sox_args.drop(1)]
    end

    def drain(reader)
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
          @sleeper.call(0.005)
          next
        end
        remaining = remaining.byteslice(frames * BYTES_PER_FRAME..)
      end
    end

    def terminate(pid)
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
