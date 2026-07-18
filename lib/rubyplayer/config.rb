require "fileutils"
require_relative "config_dsl"

module RubyPlayer
  DEFAULT_FORMAT_GROUPED = lambda do |track, fmt|
    fmt.line(
      fmt.number(track.track_number),
      fmt.text(track.title, bold: true),
      fmt.duration(track.duration_ms, fg: :text_muted),
      (fmt.text(track.artist, italic: true) unless track.artist == fmt.album_artist),
      fmt.stars(track.rating)
    )
  end

  DEFAULT_FORMAT_UNGROUPED = lambda do |track, fmt|
    fmt.line(
      fmt.text(track.album),
      fmt.number(track.track_number),
      fmt.text(track.title, bold: true),
      fmt.duration(track.duration_ms, fg: :text_muted),
      fmt.text(track.artist, italic: true),
      fmt.stars(track.rating)
    )
  end

  DEFAULTS = {
    "ui" => {
      "library_pane_percent" => 33,
      "frame_fps" => 30,
      # Idle wake-up cadence when nothing is animating. Bounded above by how
      # long a terminal resize may go unnoticed: SIGWINCH only sets a flag
      # the loop polls, so this is the worst-case resize latency.
      "idle_poll_seconds" => 0.25,
      "status_message_seconds" => 5,
      "seek_seconds" => 10,
      "format_track_grouped" => DEFAULT_FORMAT_GROUPED,
      "format_track_ungrouped" => DEFAULT_FORMAT_UNGROUPED,
      "theme" => "default",
    },
    "audio" => {
      "sample_rate" => "auto",
      "ring_buffer_ms" => 500,
      "decode_chunk_frames" => 4096,
    },
    "scanner" => { "thread_count" => 0 },
    "library" => {
      "backup_retention" => 10,
      "history_limit" => 100,
      "history_min_percent" => 5,
      "history_min_seconds_unknown" => 30,
      "undo_depth" => 10,
      "archive_cache_dir" => File.join(Dir.home, ".cache", "rubyplayer", "archives"),
      "archive_tool" => "bsdtar",
    },
    "eq" => { "bands" => 16, "fps" => 30 },
    "glyphs" => {
      "dir" => "\u{f07b}",
      "archive" => "\u{f1c6}",
      "playlist" => "\u{f0cb}",
      "multitrack" => "\u{f0e2a}",
      "star" => "\u{2605}",
      "missing" => "\u{f071}",
      "errored" => "\u{f057}",
      "play" => "\u{f04b}",
      "pause" => "\u{f04c}",
      "eq_chars" => " \u{2581}\u{2582}\u{2583}\u{2584}\u{2585}\u{2586}\u{2587}\u{2588}",
      "focus" => "\u{e28c}",
    },
    "keymap" => { "global" => {}, "library" => {}, "tracks" => {} },
    "backends" => {},
  }.freeze

  def self.config_path
    File.join(Dir.home, ".config", "rubyplayer", "config.rb")
  end

  def self.config_sample_path
    File.expand_path("../../examples/config.rb", __dir__)
  end

  def self.data_dir
    File.join(Dir.home, ".local", "share", "rubyplayer")
  end

  def self.logger
    @logger ||= begin
      require "logger"
      FileUtils.mkdir_p(data_dir)
      Logger.new(File.join(data_dir, "rubyplayer.log"), 2, 1_048_576)
    end
  end

  class ConfigStore
    MANAGED_THEME_BEGIN = "# rubyplayer: managed theme begin"
    MANAGED_THEME_END = "# rubyplayer: managed theme end"
    MANAGED_THEME_PATTERN = /^#{Regexp.escape(MANAGED_THEME_BEGIN)}\n.*?^#{Regexp.escape(MANAGED_THEME_END)}\n?/m

    attr_reader :path, :data, :previous_path, :startup_error

    def initialize(path: RubyPlayer.config_path, sample_path: RubyPlayer.config_sample_path,
                   create_if_missing: true)
      @path = path
      @previous_path = File.join(File.dirname(path), "config-previous.rb")
      @sample_path = sample_path
      @create_if_missing = create_if_missing
      bootstrap_primary! if @create_if_missing
      @signature = file_signature
      @startup_error = nil
      @data = load_startup
    end

    def [](*keys)
      keys.reduce(@data) { |value, key| value.is_a?(Hash) ? value[key] : nil }
    end

    def reload_if_changed
      signature = file_signature
      if signature.nil? && @create_if_missing
        bootstrap_primary!
        signature = file_signature
      end
      return false if signature == @signature

      @signature = signature
      if signature.nil?
        @data = ConfigDSL.deep_copy(DEFAULTS)
      else
        source = File.binread(@path)
        candidate = ConfigDSL.evaluate(source, path: @path, defaults: DEFAULTS)
        snapshot(source)
        @data = candidate
      end
      true
    end

    def persist_theme(id)
      source = File.file?(@path) ? File.binread(@path) : ""
      user_source = source.gsub(MANAGED_THEME_PATTERN, "").rstrip
      managed = <<~RUBY
        #{MANAGED_THEME_BEGIN}
        RubyPlayer.configure { |config| config.ui.theme = #{id.to_s.inspect} }
        #{MANAGED_THEME_END}
      RUBY
      candidate_source = [user_source, managed.rstrip].reject(&:empty?).join("\n\n") + "\n"
      candidate = ConfigDSL.evaluate(candidate_source, path: @path, defaults: DEFAULTS)

      atomic_write(@path, candidate_source)
      snapshot(candidate_source)
      @data = candidate
      @signature = file_signature
      true
    end

    private

    def bootstrap_primary!
      return if File.exist?(@path)

      source_path = File.file?(@previous_path) ? @previous_path : @sample_path
      unless File.file?(source_path)
        raise ConfigError.new(
          path: source_path,
          message: "#{source_path}: config sample is missing"
        )
      end

      source = File.binread(source_path)
      exclusive_atomic_create(@path, source)
    rescue ConfigError
      raise
    rescue SystemCallError => error
      raise ConfigError.new(path: source_path || @path, original: error), cause: error
    end

    def load_startup
      return ConfigDSL.deep_copy(DEFAULTS) unless File.file?(@path)

      source = File.binread(@path)
      candidate = ConfigDSL.evaluate(source, path: @path, defaults: DEFAULTS)
      snapshot(source)
      candidate
    rescue ConfigError => primary_error
      load_previous(primary_error)
    end

    def load_previous(primary_error)
      unless File.file?(@previous_path)
        raise ConfigError.new(
          path: @path,
          original: primary_error,
          message: "#{primary_error.message}\n#{@previous_path}: fallback config is missing"
        )
      end

      begin
        source = File.binread(@previous_path)
        candidate = ConfigDSL.evaluate(source, path: @previous_path, defaults: DEFAULTS)
        @startup_error = primary_error
        candidate
      rescue ConfigError => previous_error
        raise ConfigError.new(
          path: @path,
          original: primary_error,
          message: "#{primary_error.message}\nFallback failed: #{previous_error.message}"
        )
      end
    end

    def snapshot(source)
      atomic_write(@previous_path, source)
    end

    def atomic_write(destination, source)
      FileUtils.mkdir_p(File.dirname(destination))
      temporary = "#{destination}.tmp-#{Process.pid}"
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
        file.binmode
        file.write(source)
        file.flush
        file.fsync
      end
      File.rename(temporary, destination)
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def exclusive_atomic_create(destination, source)
      FileUtils.mkdir_p(File.dirname(destination))
      nonce = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
      temporary = "#{destination}.tmp-#{Process.pid}-#{nonce}"
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        file.write(source)
        file.flush
        file.fsync
      end
      File.link(temporary, destination)
    rescue Errno::EEXIST
      raise unless File.exist?(destination)
    ensure
      FileUtils.rm_f(temporary) if temporary && File.exist?(temporary)
    end

    def file_signature
      stat = File.stat(@path)
      [stat.mtime.to_r, stat.size]
    rescue Errno::ENOENT
      nil
    end
  end
end
