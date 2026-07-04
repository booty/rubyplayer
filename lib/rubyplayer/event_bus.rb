module RubyPlayer
  # Thread-safe event queue with a select()-able wakeup pipe (self-pipe trick).
  # Producers: scanner pool, playback engine. Consumer: the main UI loop.
  #
  # The main loop blocks in IO.select on `reader` alongside stdin, so it can
  # react to both keyboard input and background events (track finished,
  # position updates, scan progress) without polling. Writing a single byte
  # to `writer` is enough to wake that select — the byte's content is never
  # read for meaning, it's purely a "something happened, go check the queue"
  # signal.
  class EventBus
    attr_reader :reader

    def initialize
      @queue = Thread::Queue.new
      @reader, @writer = IO.pipe
    end

    # Must never block, and must never call back into subscribers. Callers
    # (e.g. PlaybackEngine) publish while holding their own mutex, so
    # blocking here — or re-entering the caller synchronously — would risk
    # deadlock. The queue push is unbounded/non-blocking by nature; the pipe
    # write is capped to the OS pipe buffer, which is where write_nonblock
    # matters: once the buffer is full, further wakeup bytes are redundant
    # (a wakeup is already pending), so we just drop them instead of
    # blocking on a full pipe.
    def publish(type, **payload)
      @queue << [type, payload]
      begin
        @writer.write_nonblock("!")
      rescue IO::WaitWritable, Errno::EAGAIN
        # pipe full — a wakeup byte is already pending, which is all we need
      end
    end

    # Pops everything currently queued and clears the wakeup pipe so the
    # next select() blocks until a genuinely new publish arrives.
    def drain
      events = []
      begin
        events << @queue.pop(true) while true
      rescue ThreadError
        # queue empty
      end
      begin
        @reader.read_nonblock(4096)
      rescue IO::WaitReadable, EOFError
        # nothing to clear
      end
      events
    end
  end
end
