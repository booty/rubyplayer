require "sqlite3"
require "fileutils"
require "time"

module RubyPlayer
  class Database
    SCHEMA_VERSION = 1

    SCHEMA = <<~SQL
      CREATE TABLE folders (
        id INTEGER PRIMARY KEY,
        parent_id INTEGER REFERENCES folders(id),
        name TEXT NOT NULL,
        path TEXT NOT NULL UNIQUE,
        kind TEXT NOT NULL,               -- 'dir' | 'archive' | 'playlist' | 'multitrack'
        track_count INTEGER NOT NULL DEFAULT 0,
        missing INTEGER NOT NULL DEFAULT 0,
        mtime REAL,
        size INTEGER,
        last_scanned_at TEXT
      );

      CREATE TABLE tracks (
        id INTEGER PRIMARY KEY,
        folder_id INTEGER NOT NULL REFERENCES folders(id),
        physical_path TEXT NOT NULL,
        archive_entry TEXT NOT NULL DEFAULT '',   -- '' = not inside an archive (NULL breaks UNIQUE)
        subtune_index INTEGER NOT NULL DEFAULT 0,
        backend TEXT NOT NULL,
        format TEXT NOT NULL,
        title TEXT, album TEXT, artist TEXT, composer TEXT,
        track_number INTEGER,
        duration_ms INTEGER,
        file_mtime REAL,                          -- stat data for the Scanner's change diff
        file_size INTEGER,
        rating INTEGER CHECK (rating IS NULL OR rating BETWEEN 1 AND 6),
        missing INTEGER NOT NULL DEFAULT 0,
        errored INTEGER NOT NULL DEFAULT 0,
        added_at TEXT,
        updated_at TEXT,
        UNIQUE(physical_path, archive_entry, subtune_index)
      );

      CREATE TABLE track_metadata (
        track_id INTEGER NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
        key TEXT NOT NULL,
        value TEXT,
        PRIMARY KEY (track_id, key)
      );

      CREATE TABLE playback_history (
        id INTEGER PRIMARY KEY,
        track_id INTEGER NOT NULL REFERENCES tracks(id),
        started_at TEXT NOT NULL,
        ended_at TEXT NOT NULL
      );

      CREATE INDEX idx_tracks_folder ON tracks(folder_id);
      CREATE INDEX idx_tracks_rating ON tracks(rating);
      CREATE INDEX idx_tracks_path ON tracks(physical_path);
      CREATE INDEX idx_folders_parent ON folders(parent_id);
      CREATE INDEX idx_history_started ON playback_history(started_at);
    SQL

    def initialize(path:, backup_retention: 10)
      @path = path
      @write_mutex = Mutex.new
      FileUtils.mkdir_p(File.dirname(path))
      backup!(backup_retention) if File.exist?(path)
      open_handle
      unless user_version == SCHEMA_VERSION
        rebuild! unless user_version.zero?
        create_schema
      end
    end

    def write
      @write_mutex.synchronize do
        result = nil
        @db.transaction { result = yield @db }
        result
      end
    end

    def read
      yield @db
    end

    def close
      @db&.close
      @db = nil
    end

    private

    def open_handle
      @db = SQLite3::Database.new(@path)
      @db.results_as_hash = true
      @db.busy_timeout = 5000
      @db.execute("PRAGMA journal_mode = WAL")
      @db.execute("PRAGMA foreign_keys = ON")
    end

    def user_version
      @db.get_first_value("PRAGMA user_version")
    end

    def create_schema
      @db.execute_batch(SCHEMA)
      @db.execute("PRAGMA user_version = #{SCHEMA_VERSION}")
    end

    def rebuild!
      close
      [@path, "#{@path}-wal", "#{@path}-shm"].each { |f| FileUtils.rm_f(f) }
      open_handle
    end

    def backup!(retention)
      stamp = Time.now.utc.strftime("%Y%m%d%H%M%S")
      base = File.basename(@path, ".sqlite3")
      dir = File.dirname(@path)
      FileUtils.cp(@path, File.join(dir, "#{base}-#{stamp}.sqlite3"))
      backups = Dir[File.join(dir, "#{base}-*.sqlite3")].sort
      (backups.size - retention).clamp(0, backups.size).times { |i| FileUtils.rm_f(backups[i]) }
    end
  end
end
