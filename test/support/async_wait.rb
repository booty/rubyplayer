module TestSupport
  module AsyncWait
    def wait_until(timeout: 5, interval: 0.02, failure_message: "timed out waiting")
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      result = yield
      until result
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        flunk failure_message if now > deadline
        sleep interval
        result = yield
      end
      result
    end
  end
end
