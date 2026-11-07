require 'json'
require 'minitest'

module TestSupport
  # Records how long each test file's tests took (setup and teardown
  # included) and writes them as JSON to the path in RP_TEST_TIMINGS when
  # the run ends. `rake test:parallel` uses earlier runs' timings to balance
  # its shards; nothing loads this otherwise.
  class FileTimingReporter < Minitest::AbstractReporter
    ROOT = File.expand_path('../..', __dir__)

    def initialize(path)
      super()
      @path = path
      @seconds_by_file = Hash.new(0.0)
    end

    def record(result)
      file = result.source_location&.first
      @seconds_by_file[file.delete_prefix("#{ROOT}/")] += result.time if file
    end

    def report = File.write(@path, JSON.generate(@seconds_by_file))
  end
end

module Minitest
  def self.plugin_file_timings_init(_options)
    reporter << TestSupport::FileTimingReporter.new(ENV.fetch('RP_TEST_TIMINGS'))
  end
end
Minitest.extensions << 'file_timings'
