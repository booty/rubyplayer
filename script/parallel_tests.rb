# frozen_string_literal: true

require 'etc'
require 'fileutils'
require 'json'
require 'rbconfig'

# Runs the test files across several Ruby processes (`rake test:parallel`).
#
# Processes, not Minitest's parallelize_me! threads: the native audio shim
# keeps its device and ring buffer in C globals and allows one open
# AudioOutput per process, so tests sharing a process must run one at a
# time. Each process loads its own copy of the shim.
#
# Shards are balanced by each file's duration in earlier runs (recorded in
# tmp/test_timings.json by test/support/file_timings.rb), falling back to
# file size for files with no history yet.
class ParallelTests
  ROOT = File.expand_path('..', __dir__)
  TIMINGS_PATH = File.join(ROOT, 'tmp/test_timings.json')
  LOG_DIR = File.join(ROOT, 'tmp/parallel_tests')
  # Beyond this the per-process load (~0.3 s of requires and dylibs) and
  # contention for real-time playback waits outweigh the extra cores.
  MAX_DEFAULT_SHARDS = 8
  # Stands in for a file's duration before it has one: seconds per byte of
  # test source, roughly the suite-wide average.
  FALLBACK_SECONDS_PER_BYTE = 0.000_02
  SUMMARY = /(\d+) runs, (\d+) assertions, (\d+) failures, (\d+) errors, (\d+) skips/

  Shard = Struct.new(:index, :files, :estimated_seconds, :pid, :log_path, :status, :summary)

  def initialize(shard_count: nil, output: $stdout)
    @shard_count = shard_count || [Etc.nprocessors, MAX_DEFAULT_SHARDS].min
    @output = output
  end

  # Runs every shard and reports; true when all of them passed. Named like
  # Visual::Suite#passed?, which the Rakefile calls the same way.
  def passed?
    FileUtils.rm_rf(LOG_DIR)
    FileUtils.mkdir_p(LOG_DIR)
    started_at = monotonic_seconds
    shards = plan(Dir[File.join(ROOT, 'test/**/*_test.rb')].map { |path| relative(path) }.sort)
    # Two passes on purpose: every shard starts before any is waited on.
    shards.each { |shard| start(shard) }
    shards.each { |shard| finish(shard) } # rubocop:disable Style/CombinableLoops
    save_timings(shards)
    failed = shards.reject { |shard| shard.status.success? && shard.summary }
    report(shards, failed, monotonic_seconds - started_at)
    failed.empty?
  end

  private

  # Longest-processing-time first: give each file, slowest first, to the
  # shard with the least estimated work so far.
  def plan(files)
    timings = load_timings
    shards = Array.new([@shard_count, files.size].min) do |index|
      Shard.new(index: index, files: [], estimated_seconds: 0.0)
    end
    estimates = files.to_h do |file|
      [file, timings.fetch(file) do
        File.size(File.join(ROOT, file)) * FALLBACK_SECONDS_PER_BYTE
      end]
    end
    estimates.sort_by { |_file, seconds| -seconds }.each do |file, seconds|
      shard = shards.min_by(&:estimated_seconds)
      shard.files << file
      shard.estimated_seconds += seconds
    end
    shards
  end

  def start(shard)
    shard.log_path = File.join(LOG_DIR, "shard-#{shard.index}.log")
    # ARGV is cleared before Minitest's autorun parses it as options.
    loader = 'files = ARGV.dup; ARGV.clear; files.each { |file| require File.expand_path(file) }'
    env = { 'RP_TEST_TIMINGS' => timings_path(shard) }
    shard.pid = Process.spawn(env, RbConfig.ruby, '-Itest', '-Ilib', '-e', loader, *shard.files,
                              chdir: ROOT, out: shard.log_path, err: %i[child out])
  end

  def finish(shard)
    _pid, shard.status = Process.wait2(shard.pid)
    shard.summary = File.read(shard.log_path)[SUMMARY]&.then { Regexp.last_match.captures.map(&:to_i) }
  end

  def timings_path(shard) = File.join(LOG_DIR, "timings-#{shard.index}.json")

  def load_timings
    JSON.parse(File.read(TIMINGS_PATH))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  # Merged into the previous timings so a crashed shard keeps old entries;
  # files no longer in the suite are dropped.
  def save_timings(shards)
    current_files = shards.flat_map(&:files)
    timings = load_timings.slice(*current_files)
    shards.each do |shard|
      timings.merge!(JSON.parse(File.read(timings_path(shard))))
    rescue Errno::ENOENT, JSON::ParserError
      next
    end
    File.write(TIMINGS_PATH, JSON.pretty_generate(timings.sort.to_h))
  end

  def report(shards, failed, elapsed_seconds)
    failed.each do |shard|
      @output.puts "---- shard #{shard.index} failed (#{shard.files.size} files); full log: #{shard.log_path}"
      @output.puts File.read(shard.log_path)
    end
    totals = shards.filter_map(&:summary).transpose.map(&:sum)
    runs, assertions, failures, errors, skips = totals.empty? ? [0] * 5 : totals
    @output.puts format('%<shards>d shards in %<seconds>.1fs: %<runs>d runs, %<assertions>d assertions, ' \
                        '%<failures>d failures, %<errors>d errors, %<skips>d skips',
                        shards: shards.size, seconds: elapsed_seconds, runs: runs, assertions: assertions,
                        failures: failures, errors: errors, skips: skips)
  end

  def relative(path) = path.delete_prefix("#{ROOT}/")
  def monotonic_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC)
end
