require "tomlrb"

module RubyPlayer
  DEFAULTS = {
    "ui" => {
      "library_pane_percent" => 33,
      "frame_fps" => 30,
      "status_message_seconds" => 5,
      "format_string_grouped" => "{track_number} {title} {duration} {artist?} {rating}",
      "format_string_ungrouped" => "{album} {track_number} {title} {duration} {artist?} {rating}",
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

    private

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
