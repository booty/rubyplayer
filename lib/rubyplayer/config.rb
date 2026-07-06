require "tomlrb"
require "fileutils"

module RubyPlayer
  DEFAULTS = {
    "ui" => {
      "library_pane_percent" => 33,
      "frame_fps" => 30,
      "status_message_seconds" => 5,
      "seek_seconds" => 10,
      "format_string_grouped" => "{track_number} {title} {duration} {artist?} {rating}",
      "format_string_ungrouped" => "{album} {track_number} {title} {duration} {artist?} {rating}",
      "theme" => "default",
    },
    "audio" => {
      "sample_rate" => "auto",   # "auto" = device native, or an integer Hz
      "ring_buffer_ms" => 500,
      "decode_chunk_frames" => 4096,
    },
    "scanner" => {
      "thread_count" => 0,       # 0 = number of CPU cores
    },
    "library" => {
      "backup_retention" => 10,
      "history_limit" => 100,
      "history_min_percent" => 5,
      "history_min_seconds_unknown" => 30,
      "undo_depth" => 10,
      # extracted-archive cache; entries are content-keyed so this is safe
      # to delete at any time (next scan/play re-extracts)
      "archive_cache_dir" => File.join(Dir.home, ".cache", "rubyplayer", "archives"),
      "archive_tool" => "bsdtar", # reads .zip/.7z/.rar; ships with macOS
    },
    "eq" => { "bands" => 16, "fps" => 30 },
    "glyphs" => {
      "dir" => "\u{f07b}",        #  folder
      "archive" => "\u{f1c6}",    #  zip
      "playlist" => "\u{f0cb}",   #  list
      "multitrack" => "\u{f0e2a}", # 󰸪 chip
      "star" => "\u{2605}",       # ★
      "missing" => "\u{f071}",    #  warning
      "errored" => "\u{f057}",    #  circle-x
      "play" => "\u{f04b}",       #
      "pause" => "\u{f04c}",      #
      "eq_chars" => " \u{2581}\u{2582}\u{2583}\u{2584}\u{2585}\u{2586}\u{2587}\u{2588}",
    },
    "keymap" => { "global" => {}, "library" => {}, "tracks" => {} },
  }.freeze

  def self.config_path
    File.join(Dir.home, ".config", "rubyplayer", "config.toml")
  end

  def self.data_dir
    File.join(Dir.home, ".local", "share", "rubyplayer")
  end

  def self.logger
    @logger ||= begin
      require "logger"
      require "fileutils"
      FileUtils.mkdir_p(data_dir)
      Logger.new(File.join(data_dir, "rubyplayer.log"), 2, 1_048_576) # 2 rotations, 1MB
    end
  end

  class ConfigStore
    attr_reader :path, :data

    def initialize(path: RubyPlayer.config_path)
      @path = path
      @mtime = safe_mtime
      @data = deep_merge(DEFAULTS, load_file)
    end

    def [](*keys)
      keys.reduce(@data) { |h, k| h.is_a?(Hash) ? h[k] : nil }
    end

    # Returns true if the file changed on disk and was re-merged.
    def reload_if_changed
      m = safe_mtime
      return false if m == @mtime
      @mtime = m
      @data = deep_merge(DEFAULTS, load_file)
      true
    end

    # Called only from the in-app theme picker. Patches just the "theme" line
    # under [ui] in the on-disk file rather than round-tripping the whole
    # thing -- there's no TOML writer in this project's dependencies, and
    # rewriting the full file risks mangling a user's hand-edited comments
    # for the sake of persisting one scalar.
    def persist_theme(id)
      id = id.to_s
      @data = deep_merge(@data, { "ui" => { "theme" => id } })
      write_theme_line(id)
      @mtime = safe_mtime # our own write, not an external change: skip the next reload
    end

    private

    def write_theme_line(id)
      lines = File.exist?(@path) ? File.readlines(@path) : []
      in_ui = false
      ui_header_at = nil
      replaced = false
      lines.each_with_index do |line, i|
        stripped = line.strip
        if stripped =~ /\A\[(.+)\]\z/
          in_ui = (Regexp.last_match(1) == "ui")
          ui_header_at = i if in_ui
        elsif in_ui && stripped =~ /\Atheme\s*=/
          lines[i] = "theme = #{id.inspect}\n"
          replaced = true
        end
      end
      unless replaced
        if ui_header_at
          lines.insert(ui_header_at + 1, "theme = #{id.inspect}\n")
        else
          lines << "\n" unless lines.empty?
          lines << "[ui]\n" << "theme = #{id.inspect}\n"
        end
      end
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, lines.join)
    end

    def safe_mtime
      File.mtime(@path)
    rescue Errno::ENOENT
      nil
    end

    def load_file
      return {} unless File.exist?(@path)
      Tomlrb.load_file(@path)
    rescue StandardError
      {} # invalid TOML must never take the app down; defaults win
    end

    def deep_merge(a, b)
      a.merge(b) do |_k, old, new|
        old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
      end
    end
  end
end
