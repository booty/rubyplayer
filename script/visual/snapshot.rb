# frozen_string_literal: true

require 'fileutils'
require 'json'
require 'open3'
require 'shellwords'
require 'tmpdir'
require_relative 'measure'

module Visual
  # Opens a real Kitty or iTerm2 window running the harness, waits for the
  # art placement to settle, captures just that window, and measures it.
  # macOS only: needs Screen Recording permission for the calling terminal.
  # Kitty windows open in the background; iTerm2 windows take focus for the
  # few seconds of a capture, then hand it back.
  class Snapshot
    ROOT = File.expand_path('../..', __dir__)
    HARNESS = File.join(__dir__, 'harness.rb')
    KITTY_APP = '/Applications/kitty.app'
    TERMINALS = %w[kitty iterm].freeze
    # The placement must hold this long before capture: a resize repaints
    # after resize_settle_seconds, and a capture mid-repaint is meaningless.
    STABLE_SECONDS = 1.0
    TIMEOUT_SECONDS = 30

    attr_reader :png_path, :status, :log

    def initialize(terminal:, cols:, rows:, mode:, cover:, out_dir:)
      raise ArgumentError, "terminal must be one of #{TERMINALS.join(', ')}" unless TERMINALS.include?(terminal)

      @terminal = terminal
      @cols = cols
      @rows = rows
      @mode = mode
      @cover = cover
      @out_dir = out_dir
      @name = "#{terminal}-#{mode}-#{cols}x#{rows}-#{cover.join('x')}"
      @png_path = File.join(out_dir, "#{@name}.png")
    end

    def run
      FileUtils.mkdir_p(@out_dir)
      Dir.mktmpdir('rp-visual') do |work|
        prepare(work)
        send("run_#{@terminal}", work)
      end
      self
    end

    def measurement = @measurement ||= Measure.from_png(@png_path).result

    private

    def prepare(work)
      music = File.join(work, 'music')
      FileUtils.mkdir_p(music)
      FileUtils.cp(File.join(ROOT, 'fixtures', 'space-debris.mod'), music)
      width, height = @cover
      side = [width, height].min / 2
      box = "drawbox=x=#{(width - side) / 2}:y=#{(height - side) / 2}:w=#{side}:h=#{side}:color=0x00ffff:t=fill"
      run!('ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', "color=c=0xff00ff:s=#{width}x#{height}",
           '-vf', box, '-frames:v', '1', File.join(music, 'cover.png'))
    end

    def run_kitty(work)
      # Unix socket paths are capped near 104 bytes, too short for the
      # scratch directories this usually runs under.
      socket = "/tmp/rp-visual-#{Process.pid}.sock"
      # open -g launches without taking focus, so typing elsewhere during a
      # run doesn't land in the harness as keystrokes.
      run!('open', '-g', '-n', '-a', KITTY_APP, '--args', '--config', 'NONE', '-o', 'allow_remote_control=yes',
           '-o', 'macos_quit_when_last_window_closed=yes', '--listen-on', "unix:#{socket}",
           '-o', "initial_window_width=#{@cols}c", '-o', "initial_window_height=#{@rows}c",
           '-o', 'remember_window_size=no', '--title', @name, RbConfig.ruby, HARNESS, work, @mode)
      begin
        wait_for(work) { File.socket?(socket) }
        listing, = Open3.capture2('kitten', '@', '--to', "unix:#{socket}", 'ls')
        capture(JSON.parse(listing).first.fetch('platform_window_id'), work)
      ensure
        system('kitten', '@', '--to', "unix:#{socket}", 'close-window', '--match', 'all', out: File::NULL,
                                                                                          err: File::NULL)
        FileUtils.rm_f(socket)
      end
    end

    def run_iterm(work)
      # iTerm2 starts commands with a minimal environment: no Homebrew
      # ffmpeg, and the system Ruby instead of this one.
      script = File.join(work, 'harness.sh')
      File.write(script, <<~SH)
        #!/bin/sh
        export PATH=#{ENV.fetch('PATH').shellescape}
        exec #{RbConfig.ruby.shellescape} #{HARNESS.shellescape} #{work.shellescape} #{@mode.shellescape}
      SH
      File.chmod(0o755, script)
      # Creating an iTerm2 window always activates iTerm2, so focus can only
      # be handed back afterwards; keys typed meanwhile reach the harness.
      frontmost = osascript('tell application "System Events" to get name of first process whose frontmost is true')
      window_id = osascript(<<~APPLESCRIPT).to_i
        tell application "iTerm2"
          set w to (create window with default profile command "#{script}")
          tell current session of w
            set columns to #{@cols}
            set rows to #{@rows}
          end tell
          return id of w
        end tell
      APPLESCRIPT
      begin
        capture(window_id, work)
      ensure
        osascript(%(tell application "iTerm2" to close (first window whose id is #{window_id})))
        osascript(%(tell application "System Events" to set frontmost of process #{frontmost.inspect} to true))
      end
    end

    def capture(window_id, work)
      status_path = File.join(work, 'status.json')
      stable_since = nil
      last = nil
      wait_for(work) do
        current = File.file?(status_path) ? File.read(status_path) : nil
        if current != last
          last = current
          stable_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end
        status = current && JSON.parse(current)
        status && status['placement'] && !status['settling'] &&
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - stable_since >= STABLE_SECONDS
      end
      @status = JSON.parse(last)
      log = File.join(work, 'harness.log')
      @log = File.file?(log) ? File.read(log) : ''
      run!('screencapture', '-x', '-o', '-l', window_id.to_s, @png_path)
    end

    def wait_for(work)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TIMEOUT_SECONDS
      until yield
        raise timeout_error(work) if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.1
      end
    end

    def timeout_error(work)
      details = %w[status.json harness.log].filter_map do |name|
        path = File.join(work, name)
        "#{name}:\n#{File.read(path).lines.last(20).join}" if File.file?(path)
      end
      "#{@name}: timed out after #{TIMEOUT_SECONDS}s\n#{details.join("\n")}"
    end

    def osascript(source)
      output, status = Open3.capture2('osascript', '-e', source)
      raise "osascript failed: #{source}" unless status.success?

      output.strip
    end

    def run!(*command)
      _output, error, status = Open3.capture3(*command)
      raise "#{command.first} failed: #{error}" unless status.success?
    end
  end
end
