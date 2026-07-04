# Retro Music Player — Phase 1 (MVP) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working macOS terminal music player: scans directories of retro game/tracker music into a SQLite library, browses it in a two-pane truecolor TUI, and plays it glitch-free through CoreAudio via miniaudio, with queue/undo, ratings, history, and a hot-reloaded TOML config.

**Architecture:** Threaded single process. Main thread runs the input/render event loop; a scanner thread + bounded FFI extractor pool sync the library; a decoder thread renders PCM through backend C libraries (libgme, libopenmpt) into a C-side ring buffer; miniaudio's native callback thread drains it to CoreAudio and never touches Ruby. Commands flow inward (UI → services), events flow outward (services → UI) through an EventBus. Spec: `docs/superpowers/specs/2026-07-03-retro-music-player-design.md`.

**Tech Stack:** Ruby 4.x, ffi, sqlite3, tomlrb, tty-reader, tty-screen, pastel, minitest; C shim over vendored miniaudio.h; Homebrew libgme + libopenmpt.

## Global Constraints

- macOS arm64 only; Homebrew prefix is `/opt/homebrew`.
- Ruby 4.x, pinned via `.ruby-version` (adjust the patch level to whatever `mise ls ruby` provides; the file contents in Task 1 say `4.0` — that is intentional).
- Before Task 6: `brew install libgme libopenmpt` must have been run.
- All application code lives under the `RubyPlayer` module namespace, files under `lib/rubyplayer/`.
- Tests: minitest, files at `test/<name>_test.rb`, run a single file with `bundle exec ruby -Itest test/<name>_test.rb`, run all with `bundle exec rake test`. Every test file starts with `require "test_helper"`.
- Test fixtures are REAL music files at `./fixtures` (repo root). Phase 1 uses: `mega-man-2.nsf`, `shantae.gbs`, `air-zonk.hes`, `earthbound-megaton-walk.spc`, `alisa-dragoon-introduction.vgm`, `scrap-brean-zone.vgm` (gme); `space-debris.mod`, `deadlock.xm`, `leynos-2nd-pm.s3m` (openmpt); `warrior.jpg` (unsupported). Archives (`.zip/.7z/.rar`) and `air-zonk.m3u` are Phase 2 — ignore them.
- Never `eval` config content. Config values are parsed with whitelists and fail gracefully.
- Prefer a config value with a documented default over a magic number — new tunables go in `RubyPlayer::DEFAULTS` (Task 2).
- Timestamps stored in SQLite are ISO-8601 UTC TEXT: `Time.now.utc.iso8601` (`require "time"`).
- Commands flow inward, events flow outward: UI calls service methods; services publish to the EventBus; services never call into UI code.
- The canonical audio format is float32 interleaved stereo, packed in Ruby `String`s via `pack("e*")`.
- **Schema deviation from spec (intentional):** `tracks.archive_entry` is `TEXT NOT NULL DEFAULT ''` (not nullable) because SQLite treats NULLs as distinct in UNIQUE indexes, which would break upsert idempotency. `''` means "not inside an archive".
- Commit after every task with the message given in its final step.

## File Structure

```
Gemfile / Rakefile / .ruby-version / .gitignore    Task 1
bin/rubyplayer                                     Task 20 (executable entry point)
ext/rp_audio/miniaudio.h                           Task 5 (vendored, committed)
ext/rp_audio/rp_audio.c                            Task 5 (C shim: ring buffer + device)
lib/rubyplayer.rb                                  Task 1 (requires everything)
lib/rubyplayer/config.rb                           Task 2 (DEFAULTS + ConfigStore)
lib/rubyplayer/database.rb                         Task 3 (open/backup/schema/version)
lib/rubyplayer/track.rb                            Task 4 (Track struct)
lib/rubyplayer/library.rb                          Task 4 (queries + upserts)
lib/rubyplayer/audio_output.rb                     Task 5 (FFI to rp_audio dylib)
lib/rubyplayer/backends/gme.rb                     Task 6
lib/rubyplayer/backends/openmpt.rb                 Task 7
lib/rubyplayer/backends/registry.rb                Task 8
lib/rubyplayer/scanner.rb                          Task 9 (walk + diff → work list)
lib/rubyplayer/extractor_pool.rb                   Task 10 (metadata worker pool)
lib/rubyplayer/play_queue.rb                       Task 11 (queue + undo/redo)
lib/rubyplayer/template.rb                         Task 12 (format-string evaluator)
lib/rubyplayer/keymap.rb                           Task 13
lib/rubyplayer/level_tap.rb                        Task 14 (EQ band magnitudes)
lib/rubyplayer/playback_engine.rb                  Task 14
lib/rubyplayer/event_bus.rb                        Task 15
lib/rubyplayer/ui/screen.rb                        Task 16 (diff renderer)
lib/rubyplayer/ui/library_pane.rb                  Task 17
lib/rubyplayer/ui/tracks_pane.rb                   Task 18
lib/rubyplayer/ui/bottom_lines.rb                  Task 19 (playback/status/hotkey lines)
lib/rubyplayer/ui/app.rb                           Task 20 (wiring + main loop)
lib/rubyplayer/native/                             build output dir (dylib, gitignored)
test/test_helper.rb                                Task 1
test/<component>_test.rb                           per task
```

Naming note: the queue class is `PlayQueue` (not `Queue`) to avoid colliding with Ruby's built-in `Thread::Queue` alias `::Queue`.

---

### Task 1: Project Scaffold

**Files:**
- Create: `Gemfile`, `Rakefile`, `.ruby-version`, `.gitignore`, `lib/rubyplayer.rb`, `test/test_helper.rb`, `test/scaffold_test.rb`

**Interfaces:**
- Produces: `RubyPlayer::VERSION` (String); `FIXTURES` constant in tests (absolute path to `./fixtures`); `bundle exec rake test` runs all tests.

- [ ] **Step 1: Create version manager pin and Gemfile**

`.ruby-version`:
```
4.0
```

`Gemfile`:
```ruby
source "https://rubygems.org"

gem "ffi", "~> 1.17"
gem "sqlite3", "~> 2.0"
gem "tomlrb", "~> 2.0"
gem "tty-reader", "~> 0.9"
gem "tty-screen", "~> 0.8"
gem "pastel", "~> 0.8"

group :development, :test do
  gem "minitest", "~> 5.20"
  gem "rake", "~> 13.0"
end
```

Run: `ruby -v` — if it does not report 4.x, install via `mise use ruby@4` (or rbenv equivalent) before continuing. Then run `bundle install`.
Expected: `Bundle complete!`

- [ ] **Step 2: Create Rakefile, .gitignore, lib entry, test helper**

`Rakefile`:
```ruby
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test" << "lib"
  t.pattern = "test/**/*_test.rb"
end

task default: :test
```

`.gitignore`:
```
.DS_Store
lib/rubyplayer/native/*.dylib
tmp/
```

`lib/rubyplayer.rb`:
```ruby
module RubyPlayer
  VERSION = "0.1.0"
end

require_relative "rubyplayer/config"
```
(The `require_relative` will fail until Task 2 creates config.rb — for this task only, comment that line out, then uncomment it in Task 2. Each later task appends its own `require_relative` lines here; keep them in task order.)

`test/test_helper.rb`:
```ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "minitest/autorun"
require "rubyplayer"

FIXTURES = File.expand_path("../fixtures", __dir__)
```

`test/scaffold_test.rb`:
```ruby
require "test_helper"

class ScaffoldTest < Minitest::Test
  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, RubyPlayer::VERSION)
  end

  def test_fixtures_present
    assert File.exist?(File.join(FIXTURES, "space-debris.mod"))
    assert File.exist?(File.join(FIXTURES, "mega-man-2.nsf"))
  end
end
```

- [ ] **Step 3: Run tests**

Run: `bundle exec rake test`
Expected: `2 runs, 3 assertions, 0 failures, 0 errors`

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock Rakefile .ruby-version .gitignore lib/ test/
git commit -m "feat: project scaffold with minitest"
```

---

### Task 2: ConfigStore (TOML + defaults + hot-reload)

**Files:**
- Create: `lib/rubyplayer/config.rb`
- Modify: `lib/rubyplayer.rb` (uncomment/add `require_relative "rubyplayer/config"`)
- Test: `test/config_test.rb`

**Interfaces:**
- Produces:
  - `RubyPlayer::DEFAULTS` — nested Hash of all default settings (string keys).
  - `RubyPlayer::ConfigStore.new(path:)` — loads TOML at `path` deep-merged over DEFAULTS; missing/invalid file ⇒ pure defaults.
  - `config[*keys]` — e.g. `config["audio", "sample_rate"]` ⇒ `"auto"`. Returns nil for unknown keys.
  - `config.reload_if_changed` ⇒ true and re-merges when file mtime changed, else false.
  - `RubyPlayer.config_path` ⇒ `~/.config/rubyplayer/config.toml`; `RubyPlayer.data_dir` ⇒ `~/.local/share/rubyplayer`.

- [ ] **Step 1: Write the failing test**

`test/config_test.rb`:
```ruby
require "test_helper"
require "tmpdir"

class ConfigTest < Minitest::Test
  def test_defaults_when_no_file
    c = RubyPlayer::ConfigStore.new(path: "/nonexistent/config.toml")
    assert_equal "auto", c["audio", "sample_rate"]
    assert_equal 33, c["ui", "library_pane_percent"]
    assert_equal 16, c["eq", "bands"]
    assert_nil c["nope", "nothing"]
  end

  def test_file_overrides_defaults_deeply
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "[audio]\nsample_rate = 48000\n")
      c = RubyPlayer::ConfigStore.new(path: path)
      assert_equal 48000, c["audio", "sample_rate"]
      assert_equal 500, c["audio", "ring_buffer_ms"] # untouched default survives
    end
  end

  def test_invalid_toml_falls_back_to_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "= this is [not toml")
      c = RubyPlayer::ConfigStore.new(path: path)
      assert_equal "auto", c["audio", "sample_rate"]
    end
  end

  def test_reload_if_changed
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.toml")
      File.write(path, "[eq]\nbands = 8\n")
      c = RubyPlayer::ConfigStore.new(path: path)
      assert_equal 8, c["eq", "bands"]
      refute c.reload_if_changed
      File.write(path, "[eq]\nbands = 32\n")
      File.utime(Time.now + 2, Time.now + 2, path) # force mtime change
      assert c.reload_if_changed
      assert_equal 32, c["eq", "bands"]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/config_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::ConfigStore` (NameError)

- [ ] **Step 3: Implement**

`lib/rubyplayer/config.rb`:
```ruby
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
```

In `lib/rubyplayer.rb`, ensure the line `require_relative "rubyplayer/config"` is active (uncommented).

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/config_test.rb`
Expected: `4 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/config.rb test/config_test.rb
git commit -m "feat: ConfigStore with TOML defaults, deep merge, hot-reload"
```

---

### Task 3: Database (open, WAL, backup, schema version guard)

**Files:**
- Create: `lib/rubyplayer/database.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/database"`)
- Test: `test/database_test.rb`

**Interfaces:**
- Produces:
  - `RubyPlayer::Database.new(path:, backup_retention: 10)` — backs up an existing DB to `<name>-YYYYmmdd-HHMMSS.sqlite3` beside it (pruning to `backup_retention` newest), opens with WAL + foreign keys + busy_timeout, rebuilds from scratch if `PRAGMA user_version` doesn't match `Database::SCHEMA_VERSION`, creates the schema on a fresh file.
  - `Database::SCHEMA_VERSION` — Integer, currently `1`.
  - `db.write { |sqlite| ... }` — serialized write access (Mutex + transaction). All writes anywhere in the app go through this.
  - `db.read { |sqlite| ... }` — plain access for reads (WAL allows concurrent readers).
  - `db.close`
  - The raw handle passed to blocks is a `SQLite3::Database` with `results_as_hash = true`.

- [ ] **Step 1: Write the failing test**

`test/database_test.rb`:
```ruby
require "test_helper"
require "tmpdir"
require "fileutils"

class DatabaseTest < Minitest::Test
  def with_db_path
    Dir.mktmpdir { |dir| yield File.join(dir, "library.sqlite3") }
  end

  def test_creates_schema_on_fresh_file
    with_db_path do |path|
      db = RubyPlayer::Database.new(path: path)
      tables = db.read { |s| s.execute("SELECT name FROM sqlite_master WHERE type='table'") }
                 .map { |r| r["name"] }
      assert_includes tables, "folders"
      assert_includes tables, "tracks"
      assert_includes tables, "track_metadata"
      assert_includes tables, "playback_history"
      version = db.read { |s| s.get_first_value("PRAGMA user_version") }
      assert_equal RubyPlayer::Database::SCHEMA_VERSION, version
      db.close
    end
  end

  def test_backs_up_existing_db_on_open
    with_db_path do |path|
      RubyPlayer::Database.new(path: path).close
      RubyPlayer::Database.new(path: path).close
      backups = Dir[File.join(File.dirname(path), "library-*.sqlite3")]
      assert_equal 1, backups.size
    end
  end

  def test_prunes_backups_to_retention
    with_db_path do |path|
      dir = File.dirname(path)
      RubyPlayer::Database.new(path: path).close
      5.times { |i| FileUtils.touch(File.join(dir, "library-2020010100000#{i}.sqlite3")) }
      RubyPlayer::Database.new(path: path, backup_retention: 3).close
      assert_equal 3, Dir[File.join(dir, "library-*.sqlite3")].size
    end
  end

  def test_rebuilds_on_schema_version_mismatch
    with_db_path do |path|
      db = RubyPlayer::Database.new(path: path)
      db.write { |s| s.execute("INSERT INTO folders (name, path, kind) VALUES ('x', '/x', 'dir')") }
      db.read { |s| s.execute("PRAGMA user_version = 999") }
      db.close
      db2 = RubyPlayer::Database.new(path: path)
      count = db2.read { |s| s.get_first_value("SELECT COUNT(*) FROM folders") }
      assert_equal 0, count # rebuilt fresh
      db2.close
    end
  end

  def test_write_is_transactional_and_serialized
    with_db_path do |path|
      db = RubyPlayer::Database.new(path: path)
      threads = 4.times.map do
        Thread.new do
          10.times do
            db.write { |s| s.execute("INSERT INTO folders (name, path, kind) VALUES ('t', 'p' || abs(random()), 'dir')") }
          end
        end
      end
      threads.each(&:join)
      assert_equal 40, db.read { |s| s.get_first_value("SELECT COUNT(*) FROM folders") }
      db.close
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/database_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::Database`

- [ ] **Step 3: Implement**

`lib/rubyplayer/database.rb`:
```ruby
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
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/database"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/database_test.rb`
Expected: `5 runs ... 0 failures, 0 errors`
Note: `test_backs_up_existing_db_on_open` can collide timestamps if two backups happen in the same second — it opens the DB twice, producing one backup file plus possibly overwriting; the assertion is `== 1` which holds either way.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/database.rb test/database_test.rb
git commit -m "feat: Database with WAL, startup backup, schema version guard"
```

---

### Task 4: Track struct + Library queries

**Files:**
- Create: `lib/rubyplayer/track.rb`, `lib/rubyplayer/library.rb`
- Modify: `lib/rubyplayer.rb` (add requires for both)
- Test: `test/library_test.rb`

**Interfaces:**
- Consumes: `Database#read` / `Database#write` (Task 3).
- Produces:
  - `RubyPlayer::Track` — `Struct.new(:id, :folder_id, :physical_path, :archive_entry, :subtune_index, :backend, :format, :title, :album, :artist, :composer, :track_number, :duration_ms, :rating, :missing, :errored, keyword_init: true)` plus `Track.from_row(hash)`.
  - `RubyPlayer::Library.new(db)` with:
    - `upsert_folder(parent_id:, name:, path:, kind:, mtime: nil, size: nil)` ⇒ folder id (Integer). Idempotent on `path`.
    - `upsert_track(attrs)` ⇒ track id. `attrs` keys: `folder_id, physical_path, archive_entry ("" default), subtune_index (0 default), backend, format, title, album, artist, composer, track_number, duration_ms, file_mtime (nil default), file_size (nil default), errored (0 default)`. Re-upsert updates metadata, clears `missing`, PRESERVES `rating`.
    - `roots` ⇒ [folder Hash] where `parent_id IS NULL AND missing=0 AND track_count>0`, ordered by name.
    - `children_of(folder_id)` ⇒ [folder Hash] with same visibility filter.
    - `tracks_under(folder_id)` ⇒ [Track] recursive (CTE), `missing=0`, ordered by physical_path, subtune_index.
    - `favorites` ⇒ [Track] `rating >= 4`, ordered by rating DESC, title.
    - `history(limit: 100)` ⇒ [{track: Track, started_at:, ended_at:}] newest first.
    - `record_history(track_id:, started_at:, ended_at:)` (ISO-8601 strings).
    - `set_rating(track_id, rating_or_nil)`
    - `mark_missing(track_ids:, folder_ids:)` — sets `missing=1` on the given ids.
    - `recompute_counts!` — recomputes every folder's recursive `track_count` (bottom-up in Ruby, batch UPDATE).
    - `folder_stats` ⇒ `{folders: n, tracks: n}` (non-missing).
    - `find_track(id)` ⇒ Track or nil. `rating_of(track_id)` ⇒ Integer or nil.
    - `db_paths_under(root)` ⇒ `{tracks: {physical_path => {mtime:, size:, ids: [track ids]}}, folders: {path => {id:, mtime:, size:}}}` — everything the DB knows under `root`, for the Scanner's diff (Task 9). Track stat data comes from the `file_mtime`/`file_size` columns (grouped by `physical_path`, since one file may hold many subtune rows).

- [ ] **Step 1: Write the failing test**

`test/library_test.rb`:
```ruby
require "test_helper"
require "tmpdir"

class LibraryTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@dir, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @root = @lib.upsert_folder(parent_id: nil, name: "Music", path: "/m", kind: "dir")
    @sub = @lib.upsert_folder(parent_id: @root, name: "Sega", path: "/m/sega", kind: "dir")
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@dir)
  end

  def add_track(path, folder: @sub, subtune: 0, title: "T", rating: nil)
    id = @lib.upsert_track(folder_id: folder, physical_path: path, subtune_index: subtune,
                           backend: "gme", format: "vgm", title: title, album: "A",
                           artist: "Ar", composer: "C", track_number: 1, duration_ms: 60_000)
    @lib.set_rating(id, rating) if rating
    id
  end

  def test_upsert_folder_is_idempotent_on_path
    id2 = @lib.upsert_folder(parent_id: nil, name: "Music", path: "/m", kind: "dir")
    assert_equal @root, id2
  end

  def test_upsert_track_idempotent_and_preserves_rating
    id = add_track("/m/sega/a.vgm")
    @lib.set_rating(id, 5)
    id2 = @lib.upsert_track(folder_id: @sub, physical_path: "/m/sega/a.vgm",
                            backend: "gme", format: "vgm", title: "New Title",
                            album: "A", artist: "Ar", composer: "C",
                            track_number: 1, duration_ms: 61_000)
    assert_equal id, id2
    t = @lib.find_track(id)
    assert_equal "New Title", t.title
    assert_equal 5, t.rating
  end

  def test_subtunes_are_distinct_tracks
    a = add_track("/m/sega/multi.nsf", subtune: 0)
    b = add_track("/m/sega/multi.nsf", subtune: 1)
    refute_equal a, b
  end

  def test_tracks_under_is_recursive_and_skips_missing
    add_track("/m/sega/a.vgm")
    missing_id = add_track("/m/sega/gone.vgm")
    @lib.mark_missing(track_ids: [missing_id], folder_ids: [])
    tracks = @lib.tracks_under(@root)
    assert_equal ["/m/sega/a.vgm"], tracks.map(&:physical_path)
  end

  def test_recompute_counts_and_root_visibility
    assert_empty @lib.roots # zero tracks -> hidden
    add_track("/m/sega/a.vgm")
    @lib.recompute_counts!
    roots = @lib.roots
    assert_equal 1, roots.size
    assert_equal 1, roots.first["track_count"]
  end

  def test_favorites
    add_track("/m/sega/a.vgm", rating: 5)
    add_track("/m/sega/b.vgm", rating: 2)
    assert_equal ["/m/sega/a.vgm"], @lib.favorites.map(&:physical_path)
  end

  def test_history_round_trip
    id = add_track("/m/sega/a.vgm")
    @lib.record_history(track_id: id, started_at: "2026-07-04T00:00:00Z",
                        ended_at: "2026-07-04T00:01:00Z")
    h = @lib.history(limit: 10)
    assert_equal 1, h.size
    assert_equal id, h.first[:track].id
  end

  def test_rating_check_constraint
    id = add_track("/m/sega/a.vgm")
    assert_raises(SQLite3::ConstraintException) { @lib.set_rating(id, 9) }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/library_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::Library`

- [ ] **Step 3: Implement**

`lib/rubyplayer/track.rb`:
```ruby
module RubyPlayer
  Track = Struct.new(:id, :folder_id, :physical_path, :archive_entry, :subtune_index,
                     :backend, :format, :title, :album, :artist, :composer,
                     :track_number, :duration_ms, :rating, :missing, :errored,
                     keyword_init: true) do
    def self.from_row(row)
      new(id: row["id"], folder_id: row["folder_id"], physical_path: row["physical_path"],
          archive_entry: row["archive_entry"], subtune_index: row["subtune_index"],
          backend: row["backend"], format: row["format"], title: row["title"],
          album: row["album"], artist: row["artist"], composer: row["composer"],
          track_number: row["track_number"], duration_ms: row["duration_ms"],
          rating: row["rating"], missing: row["missing"], errored: row["errored"])
    end
  end
end
```

`lib/rubyplayer/library.rb`:
```ruby
require "time"

module RubyPlayer
  class Library
    def initialize(db)
      @db = db
    end

    def upsert_folder(parent_id:, name:, path:, kind:, mtime: nil, size: nil)
      @db.write do |s|
        s.execute(<<~SQL, [parent_id, name, path, kind, mtime, size, Time.now.utc.iso8601])
          INSERT INTO folders (parent_id, name, path, kind, mtime, size, last_scanned_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(path) DO UPDATE SET
            parent_id=excluded.parent_id, name=excluded.name, kind=excluded.kind,
            mtime=excluded.mtime, size=excluded.size,
            last_scanned_at=excluded.last_scanned_at, missing=0
        SQL
        s.get_first_value("SELECT id FROM folders WHERE path = ?", [path])
      end
    end

    def upsert_track(attrs)
      a = { archive_entry: "", subtune_index: 0, errored: 0,
            file_mtime: nil, file_size: nil }.merge(attrs)
      now = Time.now.utc.iso8601
      @db.write do |s|
        s.execute(<<~SQL, [a[:folder_id], a[:physical_path], a[:archive_entry], a[:subtune_index],
                           a[:backend], a[:format], a[:title], a[:album], a[:artist], a[:composer],
                           a[:track_number], a[:duration_ms], a[:file_mtime], a[:file_size],
                           a[:errored], now, now])
          INSERT INTO tracks (folder_id, physical_path, archive_entry, subtune_index,
                              backend, format, title, album, artist, composer,
                              track_number, duration_ms, file_mtime, file_size,
                              errored, added_at, updated_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(physical_path, archive_entry, subtune_index) DO UPDATE SET
            folder_id=excluded.folder_id, backend=excluded.backend, format=excluded.format,
            title=excluded.title, album=excluded.album, artist=excluded.artist,
            composer=excluded.composer, track_number=excluded.track_number,
            duration_ms=excluded.duration_ms, file_mtime=excluded.file_mtime,
            file_size=excluded.file_size, errored=excluded.errored,
            missing=0, updated_at=excluded.updated_at
        SQL
        s.get_first_value(
          "SELECT id FROM tracks WHERE physical_path = ? AND archive_entry = ? AND subtune_index = ?",
          [a[:physical_path], a[:archive_entry], a[:subtune_index]]
        )
      end
    end

    def roots
      visible_folders("parent_id IS NULL")
    end

    def children_of(folder_id)
      visible_folders("parent_id = ?", [folder_id])
    end

    def tracks_under(folder_id)
      rows = @db.read do |s|
        s.execute(<<~SQL, [folder_id])
          WITH RECURSIVE sub(id) AS (
            SELECT id FROM folders WHERE id = ?
            UNION ALL
            SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id
          )
          SELECT t.* FROM tracks t
          WHERE t.folder_id IN (SELECT id FROM sub) AND t.missing = 0
          ORDER BY t.physical_path, t.subtune_index
        SQL
      end
      rows.map { |r| Track.from_row(r) }
    end

    def favorites
      rows = @db.read do |s|
        s.execute("SELECT * FROM tracks WHERE rating >= 4 AND missing = 0 " \
                  "ORDER BY rating DESC, title")
      end
      rows.map { |r| Track.from_row(r) }
    end

    def history(limit: 100)
      rows = @db.read do |s|
        s.execute(<<~SQL, [limit])
          SELECT h.started_at, h.ended_at, t.*
          FROM playback_history h JOIN tracks t ON t.id = h.track_id
          ORDER BY h.started_at DESC LIMIT ?
        SQL
      end
      rows.map { |r| { track: Track.from_row(r), started_at: r["started_at"], ended_at: r["ended_at"] } }
    end

    def record_history(track_id:, started_at:, ended_at:)
      @db.write do |s|
        s.execute("INSERT INTO playback_history (track_id, started_at, ended_at) VALUES (?, ?, ?)",
                  [track_id, started_at, ended_at])
      end
    end

    def set_rating(track_id, rating)
      @db.write { |s| s.execute("UPDATE tracks SET rating = ? WHERE id = ?", [rating, track_id]) }
    end

    def rating_of(track_id)
      @db.read { |s| s.get_first_value("SELECT rating FROM tracks WHERE id = ?", [track_id]) }
    end

    def find_track(id)
      row = @db.read { |s| s.execute("SELECT * FROM tracks WHERE id = ?", [id]).first }
      row && Track.from_row(row)
    end

    def mark_missing(track_ids:, folder_ids:)
      return if track_ids.empty? && folder_ids.empty?
      @db.write do |s|
        track_ids.each_slice(500) do |ids|
          s.execute("UPDATE tracks SET missing = 1 WHERE id IN (#{ids.join(',')})")
        end
        folder_ids.each_slice(500) do |ids|
          s.execute("UPDATE folders SET missing = 1 WHERE id IN (#{ids.join(',')})")
        end
      end
    end

    # Bottom-up recursive track_count recompute, done in Ruby (a correlated
    # recursive CTE per row is not reliably supported by SQLite).
    def recompute_counts!
      folders = @db.read { |s| s.execute("SELECT id, parent_id FROM folders") }
      direct = Hash.new(0)
      @db.read { |s| s.execute("SELECT folder_id, COUNT(*) AS c FROM tracks WHERE missing = 0 GROUP BY folder_id") }
         .each { |r| direct[r["folder_id"]] = r["c"] }
      children = Hash.new { |h, k| h[k] = [] }
      folders.each { |f| children[f["parent_id"]] << f["id"] }
      totals = {}
      compute = lambda do |id|
        totals[id] ||= direct[id] + children[id].sum { |c| compute.call(c) }
      end
      folders.each { |f| compute.call(f["id"]) }
      @db.write do |s|
        totals.each { |id, n| s.execute("UPDATE folders SET track_count = ? WHERE id = ?", [n, id]) }
      end
    end

    def folder_stats
      @db.read do |s|
        { folders: s.get_first_value("SELECT COUNT(*) FROM folders WHERE missing = 0"),
          tracks: s.get_first_value("SELECT COUNT(*) FROM tracks WHERE missing = 0") }
      end
    end

    # For the Scanner's diff pass: everything the DB knows under `root`.
    def db_paths_under(root)
      prefix = root.chomp("/") + "/"
      tracks = {}
      folders = {}
      @db.read do |s|
        s.execute(<<~SQL, [root, "#{prefix}%"]).each do |r|
          SELECT physical_path, file_mtime, file_size, GROUP_CONCAT(id) AS ids
          FROM tracks
          WHERE missing = 0 AND (physical_path = ? OR physical_path LIKE ?)
          GROUP BY physical_path
        SQL
          tracks[r["physical_path"]] = { mtime: r["file_mtime"], size: r["file_size"],
                                         ids: r["ids"].split(",").map(&:to_i) }
        end
        s.execute("SELECT id, path, mtime, size FROM folders WHERE missing = 0 AND (path = ? OR path LIKE ?)",
                  [root, "#{prefix}%"]).each do |r|
          folders[r["path"]] = { id: r["id"], mtime: r["mtime"], size: r["size"] }
        end
      end
      { tracks: tracks, folders: folders }
    end

    private

    def visible_folders(where, params = [])
      @db.read do |s|
        s.execute("SELECT * FROM folders WHERE #{where} AND missing = 0 AND track_count > 0 ORDER BY name COLLATE NOCASE", params)
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`:
```ruby
require_relative "rubyplayer/track"
require_relative "rubyplayer/library"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/library_test.rb`
Expected: `8 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/track.rb lib/rubyplayer/library.rb test/library_test.rb
git commit -m "feat: Library queries, upserts, counts, history, favorites"
```

---

### Task 5: miniaudio C shim + AudioOutput FFI binding

The ring buffer lives in **C**, not Ruby, because miniaudio's callback runs on a native
thread that must never touch the Ruby VM. Ruby writes PCM in via FFI (releasing the GVL);
the callback drains it. One device per process (module-level C state) — that is fine for
this app and is documented on the class.

**Files:**
- Create: `ext/rp_audio/rp_audio.c`, `lib/rubyplayer/audio_output.rb`
- Create (vendored): `ext/rp_audio/miniaudio.h`
- Modify: `Rakefile` (compile task), `.gitignore` already covers the dylib
- Test: `test/audio_output_test.rb`
- Do NOT add a require to `lib/rubyplayer.rb` — `audio_output` is loaded explicitly by its users (engine, app, tests) so pure-Ruby tests never need the dylib.

**Interfaces:**
- Produces:
  - `RubyPlayer::AudioOutput.new(sample_rate: "auto", ring_buffer_ms: 500, null_backend: false)` — `"auto"` ⇒ device-native rate; `null_backend: true` uses miniaudio's null device (real-time consuming, no hardware — for tests/CI).
  - `#sample_rate` ⇒ Integer (the resolved canonical rate — Task 14's engine passes this to backends).
  - `#write(frames_string)` ⇒ Integer frames accepted (0 when full; caller retries). Input: float32 interleaved stereo packed String.
  - `#start` / `#stop` / `#paused=` / `#flush` / `#close`
  - `#writable_frames`, `#buffered_frames`, `#frames_played` (cumulative Integer, drives position display).
  - Rake: `rake compile` builds `lib/rubyplayer/native/librp_audio.dylib`; `rake test` depends on it.

- [ ] **Step 1: Vendor miniaudio (pinned)**

```bash
curl -fL -o ext/rp_audio/miniaudio.h https://raw.githubusercontent.com/mackron/miniaudio/0.11.22/miniaudio.h
```
Expected: file exists, first lines mention "miniaudio". If the tag URL 404s, use the master branch URL and note the version from the file header in the commit message.

- [ ] **Step 2: Write the C shim**

`ext/rp_audio/rp_audio.c`:
```c
/* rp_audio: minimal playback shim over miniaudio.
 * Owns a lock-free SPSC ring buffer of float32 interleaved stereo frames.
 * Producer: Ruby decoder thread via rp_write (FFI, GVL released).
 * Consumer: miniaudio's native callback — never touches Ruby.
 * Module-level state => exactly one device per process.
 */
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#include "miniaudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RP_CHANNELS 2

static ma_context g_ctx;
static ma_device g_device;
static float *g_rb;                     /* rb_capacity * RP_CHANNELS floats */
static uint64_t g_rb_capacity;          /* frames */
static _Atomic uint64_t g_read;         /* monotonically increasing frame counters */
static _Atomic uint64_t g_write;
static _Atomic int g_paused;
static _Atomic uint64_t g_frames_played;
static int g_initialized = 0;

static void data_callback(ma_device *dev, void *output, const void *input, ma_uint32 frame_count) {
    (void)dev; (void)input;
    float *out = (float *)output;
    uint64_t r = atomic_load(&g_read);
    uint64_t w = atomic_load(&g_write);
    uint64_t avail = w - r;
    ma_uint32 n = 0;
    if (!atomic_load(&g_paused))
        n = (ma_uint32)(avail < frame_count ? avail : frame_count);
    for (ma_uint32 i = 0; i < n; i++) {
        uint64_t idx = ((r + i) % g_rb_capacity) * RP_CHANNELS;
        out[i * RP_CHANNELS]     = g_rb[idx];
        out[i * RP_CHANNELS + 1] = g_rb[idx + 1];
    }
    if (n < frame_count)  /* underrun or paused: emit silence */
        memset(out + (size_t)n * RP_CHANNELS, 0,
               ((size_t)frame_count - n) * RP_CHANNELS * sizeof(float));
    atomic_store(&g_read, r + n);
    atomic_fetch_add(&g_frames_played, n);
}

/* sample_rate 0 = device native. use_null != 0 = miniaudio null backend (tests). */
int rp_init(unsigned int sample_rate, unsigned int buffer_ms, int use_null) {
    if (g_initialized) return -1;
    ma_context_config cc = ma_context_config_init();
    if (use_null) {
        ma_backend backends[] = { ma_backend_null };
        if (ma_context_init(backends, 1, &cc, &g_ctx) != MA_SUCCESS) return -2;
    } else {
        if (ma_context_init(NULL, 0, &cc, &g_ctx) != MA_SUCCESS) return -2;
    }
    ma_device_config dc = ma_device_config_init(ma_device_type_playback);
    dc.playback.format   = ma_format_f32;
    dc.playback.channels = RP_CHANNELS;
    dc.sampleRate        = sample_rate;    /* 0 => native */
    dc.dataCallback      = data_callback;
    if (ma_device_init(&g_ctx, &dc, &g_device) != MA_SUCCESS) {
        ma_context_uninit(&g_ctx);
        return -3;
    }
    g_rb_capacity = (uint64_t)g_device.sampleRate * buffer_ms / 1000;
    if (g_rb_capacity < 1024) g_rb_capacity = 1024;
    g_rb = (float *)calloc((size_t)g_rb_capacity * RP_CHANNELS, sizeof(float));
    if (!g_rb) { ma_device_uninit(&g_device); ma_context_uninit(&g_ctx); return -4; }
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_paused, 0);
    atomic_store(&g_frames_played, 0);
    g_initialized = 1;
    return 0;
}

unsigned int rp_sample_rate(void) { return g_initialized ? g_device.sampleRate : 0; }
int rp_start(void) { return ma_device_start(&g_device) == MA_SUCCESS ? 0 : -1; }
int rp_stop(void)  { return ma_device_stop(&g_device)  == MA_SUCCESS ? 0 : -1; }
void rp_set_paused(int p) { atomic_store(&g_paused, p ? 1 : 0); }

unsigned int rp_writable_frames(void) {
    return (unsigned int)(g_rb_capacity - (atomic_load(&g_write) - atomic_load(&g_read)));
}

unsigned int rp_buffered_frames(void) {
    return (unsigned int)(atomic_load(&g_write) - atomic_load(&g_read));
}

/* Copy up to frame_count frames in; returns frames accepted (may be 0 when full). */
unsigned int rp_write(const float *frames, unsigned int frame_count) {
    uint64_t r = atomic_load(&g_read);
    uint64_t w = atomic_load(&g_write);
    uint64_t space = g_rb_capacity - (w - r);
    unsigned int n = (unsigned int)(space < frame_count ? space : frame_count);
    for (unsigned int i = 0; i < n; i++) {
        uint64_t idx = ((w + i) % g_rb_capacity) * RP_CHANNELS;
        g_rb[idx]     = frames[i * RP_CHANNELS];
        g_rb[idx + 1] = frames[i * RP_CHANNELS + 1];
    }
    atomic_store(&g_write, w + n);
    return n;
}

unsigned long long rp_frames_played(void) { return atomic_load(&g_frames_played); }

/* Drop all buffered audio (seek/skip). Callers should pause first to avoid a
 * benign race where the callback resurrects a few frames. */
void rp_flush(void) { atomic_store(&g_read, atomic_load(&g_write)); }

void rp_free(void) {
    if (!g_initialized) return;
    ma_device_uninit(&g_device);
    ma_context_uninit(&g_ctx);
    free(g_rb);
    g_rb = NULL;
    g_initialized = 0;
}
```

- [ ] **Step 3: Add the compile task to the Rakefile**

Append to `Rakefile`:
```ruby
NATIVE_DYLIB = "lib/rubyplayer/native/librp_audio.dylib"

file NATIVE_DYLIB => ["ext/rp_audio/rp_audio.c", "ext/rp_audio/miniaudio.h"] do
  mkdir_p "lib/rubyplayer/native"
  sh "clang -O2 -dynamiclib -o #{NATIVE_DYLIB} ext/rp_audio/rp_audio.c " \
     "-framework CoreFoundation -framework CoreAudio -framework AudioToolbox " \
     "-lpthread -lm"
end

desc "Build the native audio shim"
task compile: NATIVE_DYLIB

task test: :compile
```

Run: `bundle exec rake compile`
Expected: clang command runs, `lib/rubyplayer/native/librp_audio.dylib` exists. (Warnings from miniaudio.h are acceptable; errors are not.)

- [ ] **Step 4: Write the failing Ruby test**

`test/audio_output_test.rb`:
```ruby
require "test_helper"
require "rubyplayer/audio_output"

class AudioOutputTest < Minitest::Test
  # The C shim is a per-process singleton, so exercise the whole lifecycle
  # in one ordered test method.
  def test_null_backend_end_to_end
    out = RubyPlayer::AudioOutput.new(sample_rate: 44_100, ring_buffer_ms: 200,
                                      null_backend: true)
    assert_equal 44_100, out.sample_rate

    silence = ([0.0] * (4096 * 2)).pack("e*")
    accepted = out.write(silence)
    assert_operator accepted, :>, 0
    assert_equal accepted, out.buffered_frames

    out.start
    sleep 0.3
    assert_operator out.frames_played, :>, 0  # null device consumes in real time

    out.paused = true
    out.flush
    assert_equal 0, out.buffered_frames
    out.stop
    out.close
  end
end
```

Run: `bundle exec ruby -Itest test/audio_output_test.rb`
Expected: FAIL — `cannot load such file -- rubyplayer/audio_output`

- [ ] **Step 5: Implement the FFI binding**

`lib/rubyplayer/audio_output.rb`:
```ruby
require "ffi"

module RubyPlayer
  module RpAudio
    extend FFI::Library
    ffi_lib File.expand_path("native/librp_audio.dylib", __dir__)
    attach_function :rp_init, [:uint, :uint, :int], :int
    attach_function :rp_sample_rate, [], :uint
    attach_function :rp_start, [], :int
    attach_function :rp_stop, [], :int
    attach_function :rp_set_paused, [:int], :void
    attach_function :rp_write, [:pointer, :uint], :uint, blocking: true
    attach_function :rp_writable_frames, [], :uint
    attach_function :rp_buffered_frames, [], :uint
    attach_function :rp_frames_played, [], :uint64
    attach_function :rp_flush, [], :void
    attach_function :rp_free, [], :void
  end

  # Playback device + C-side ring buffer. ONE instance per process (the C shim
  # holds module-level state). Input format: float32 interleaved stereo, packed
  # with Array#pack("e*").
  class AudioOutput
    BYTES_PER_FRAME = 2 * 4 # stereo float32

    attr_reader :sample_rate

    def initialize(sample_rate: "auto", ring_buffer_ms: 500, null_backend: false)
      rate = sample_rate == "auto" ? 0 : Integer(sample_rate)
      code = RpAudio.rp_init(rate, ring_buffer_ms, null_backend ? 1 : 0)
      raise "rp_audio init failed (code #{code})" unless code.zero?
      @sample_rate = RpAudio.rp_sample_rate
    end

    # Returns the number of frames accepted (0 when the buffer is full).
    def write(frames_string)
      frame_count = frames_string.bytesize / BYTES_PER_FRAME
      @ptr = FFI::MemoryPointer.new(:float, frame_count * 2) if @ptr.nil? || @ptr.size < frames_string.bytesize
      @ptr.put_bytes(0, frames_string)
      RpAudio.rp_write(@ptr, frame_count)
    end

    def start = RpAudio.rp_start
    def stop = RpAudio.rp_stop
    def paused=(flag) = RpAudio.rp_set_paused(flag ? 1 : 0)
    def writable_frames = RpAudio.rp_writable_frames
    def buffered_frames = RpAudio.rp_buffered_frames
    def frames_played = RpAudio.rp_frames_played
    def flush = RpAudio.rp_flush
    def close = RpAudio.rp_free
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/audio_output_test.rb`
Expected: `1 runs ... 0 failures, 0 errors`

Then verify real hardware manually (one-liner; you should hear ~1s of a 440 Hz tone):
```bash
bundle exec ruby -Ilib -e '
require "rubyplayer/audio_output"
out = RubyPlayer::AudioOutput.new(ring_buffer_ms: 1500)
rate = out.sample_rate
puts "device native rate: #{rate}"
tone = (0...rate).flat_map { |i| v = 0.2 * Math.sin(2 * Math::PI * 440 * i / rate.to_f); [v, v] }.pack("e*")
out.write(tone)
out.start
sleep 1.2
out.close
'
```
Expected: prints the device rate (e.g. 48000) and plays an audible tone. If running headless/CI, skip this manual check.

- [ ] **Step 7: Commit**

```bash
git add ext/rp_audio/ Rakefile lib/rubyplayer/audio_output.rb test/audio_output_test.rb
git commit -m "feat: miniaudio C shim with lock-free ring buffer + AudioOutput FFI binding"
```

---

### Task 6: GmeBackend (libgme FFI)

Prerequisite: `brew install libgme` (see Global Constraints).

**Files:**
- Create: `lib/rubyplayer/backends/gme.rb`
- Test: `test/gme_backend_test.rb`
- Do NOT require from `lib/rubyplayer.rb` (loaded lazily by the Registry, Task 8).

**Interfaces:**
- Produces (this exact shape is the Backend interface; Task 7 mirrors it):
  - `RubyPlayer::Backends::Gme.new`
  - `#name` ⇒ `"gme"`
  - `#track_count(path)` ⇒ Integer (number of subtunes; 1 for single-track formats)
  - `#metadata(path, subtune_index)` ⇒ `{title:, album:, artist:, composer:, track_number:, duration_ms:, format:}` (Strings/Integers; nils where unknown; `title` never nil — falls back to `"Track NN"`)
  - `#open(path, subtune_index, sample_rate:)` ⇒ Handle with `#read(frames)` ⇒ packed float32 stereo String or nil at end-of-track, `#seek(ms)` ⇒ bool, `#position_ms` ⇒ Integer, `#duration_ms` ⇒ Integer|nil, `#close`
  - `RubyPlayer::Backends::Gme::Error < StandardError` raised on open/decode failure.

- [ ] **Step 1: Write the failing test**

`test/gme_backend_test.rb`:
```ruby
require "test_helper"
require "rubyplayer/backends/gme"

class GmeBackendTest < Minitest::Test
  def setup
    @gme = RubyPlayer::Backends::Gme.new
  end

  def test_track_count_multitrack_nsf
    assert_operator @gme.track_count(File.join(FIXTURES, "mega-man-2.nsf")), :>, 1
  end

  def test_track_count_single_spc
    assert_equal 1, @gme.track_count(File.join(FIXTURES, "earthbound-megaton-walk.spc"))
  end

  def test_metadata_shape
    meta = @gme.metadata(File.join(FIXTURES, "alisa-dragoon-introduction.vgm"), 0)
    assert_kind_of String, meta[:title]
    refute_empty meta[:title]
    assert_equal "vgm", meta[:format]
    assert_equal 1, meta[:track_number]
  end

  def test_subtune_metadata_has_incremented_track_number
    meta = @gme.metadata(File.join(FIXTURES, "mega-man-2.nsf"), 3)
    assert_equal 4, meta[:track_number]
  end

  def test_decode_produces_bounded_float_pcm
    h = @gme.open(File.join(FIXTURES, "shantae.gbs"), 0, sample_rate: 44_100)
    data = h.read(1024)
    assert_equal 1024 * 2 * 4, data.bytesize # frames * stereo * float32
    floats = data.unpack("e*")
    assert(floats.all? { |f| f >= -1.0 && f <= 1.0 })
    refute(floats.all? { |f| f.zero? }, "expected non-silent audio")
    h.close
  end

  def test_seek_and_position
    h = @gme.open(File.join(FIXTURES, "mega-man-2.nsf"), 1, sample_rate: 44_100)
    h.read(1024)
    assert h.seek(5_000)
    assert_in_delta 5_000, h.position_ms, 500
    h.close
  end

  def test_open_bogus_file_raises
    assert_raises(RubyPlayer::Backends::Gme::Error) do
      @gme.open(File.join(FIXTURES, "warrior.jpg"), 0, sample_rate: 44_100)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/gme_backend_test.rb`
Expected: FAIL — `cannot load such file -- rubyplayer/backends/gme`
(If it fails with `LoadError ... libgme`, run `brew install libgme` first.)

- [ ] **Step 3: Implement**

`lib/rubyplayer/backends/gme.rb`:
```ruby
require "ffi"

module RubyPlayer
  module Backends
    module GmeLib
      extend FFI::Library
      ffi_lib ["gme", "libgme.dylib", "/opt/homebrew/lib/libgme.dylib"]

      GME_INFO_ONLY = -1 # special sample_rate: open for metadata only

      # gme functions return a const char* error string, or NULL on success.
      attach_function :gme_open_file, [:string, :pointer, :int], :string
      attach_function :gme_track_count, [:pointer], :int
      attach_function :gme_start_track, [:pointer, :int], :string
      attach_function :gme_play, [:pointer, :int, :pointer], :string, blocking: true
      attach_function :gme_track_ended, [:pointer], :int
      attach_function :gme_seek, [:pointer, :int], :string, blocking: true
      attach_function :gme_tell, [:pointer], :int
      attach_function :gme_set_fade, [:pointer, :int], :void
      attach_function :gme_track_info, [:pointer, :pointer, :int], :string
      attach_function :gme_free_info, [:pointer], :void
      attach_function :gme_delete, [:pointer], :void
    end

    # Mirrors gme_info_t: 16 ints then 16 const char*. Only the named leading
    # fields are used; i4..i15 / s7..s15 are reserved padding in gme.h, so this
    # layout is size-compatible across libgme 0.6.x releases.
    class GmeInfo < FFI::Struct
      layout :length, :int, :intro_length, :int, :loop_length, :int, :play_length, :int,
             :i4, :int, :i5, :int, :i6, :int, :i7, :int, :i8, :int, :i9, :int,
             :i10, :int, :i11, :int, :i12, :int, :i13, :int, :i14, :int, :i15, :int,
             :system, :string, :game, :string, :song, :string, :author, :string,
             :copyright, :string, :comment, :string, :dumper, :string,
             :s7, :string, :s8, :string, :s9, :string, :s10, :string, :s11, :string,
             :s12, :string, :s13, :string, :s14, :string, :s15, :string
    end

    class Gme
      class Error < StandardError; end

      def name = "gme"

      def track_count(path)
        with_emu(path, GmeLib::GME_INFO_ONLY) { |emu| GmeLib.gme_track_count(emu) }
      end

      def metadata(path, subtune_index)
        with_emu(path, GmeLib::GME_INFO_ONLY) do |emu|
          with_info(emu, subtune_index) do |info|
            {
              title: presence(info[:song]) || format("Track %02d", subtune_index + 1),
              album: presence(info[:game]),
              artist: presence(info[:author]),
              composer: presence(info[:author]),
              track_number: subtune_index + 1,
              duration_ms: info[:play_length].positive? ? info[:play_length] : nil,
              format: File.extname(path).delete_prefix(".").downcase,
            }
          end
        end
      end

      def open(path, subtune_index, sample_rate:)
        emu = open_emu(path, sample_rate)
        err = GmeLib.gme_start_track(emu, subtune_index)
        if err
          GmeLib.gme_delete(emu)
          raise Error, err
        end
        Handle.new(emu, subtune_index)
      end

      class Handle
        attr_reader :duration_ms

        def initialize(emu, subtune_index)
          @emu = emu
          info_ptr = FFI::MemoryPointer.new(:pointer)
          if GmeLib.gme_track_info(@emu, info_ptr, subtune_index).nil?
            info = GmeInfo.new(info_ptr.read_pointer)
            play_len = info[:play_length]
            @duration_ms = play_len.positive? ? play_len : nil
            # Looping chiptunes never end on their own; fade out at play_length.
            GmeLib.gme_set_fade(@emu, play_len) if play_len.positive?
            GmeLib.gme_free_info(info_ptr.read_pointer)
          end
        end

        # Returns packed float32 stereo, or nil once the track has ended.
        def read(frames)
          return nil if @emu.nil? || GmeLib.gme_track_ended(@emu) != 0
          samples = frames * 2
          if @buf.nil? || @buf_samples != samples
            @buf = FFI::MemoryPointer.new(:short, samples)
            @buf_samples = samples
          end
          err = GmeLib.gme_play(@emu, samples, @buf)
          raise Error, err if err
          @buf.read_bytes(samples * 2).unpack("s<*").map { |s| s / 32_768.0 }.pack("e*")
        end

        def seek(ms) = GmeLib.gme_seek(@emu, ms).nil?
        def position_ms = GmeLib.gme_tell(@emu)

        def close
          GmeLib.gme_delete(@emu) if @emu
          @emu = nil
        end
      end

      private

      def open_emu(path, sample_rate)
        out = FFI::MemoryPointer.new(:pointer)
        err = GmeLib.gme_open_file(path, out, sample_rate)
        raise Error, err if err
        out.read_pointer
      end

      def with_emu(path, sample_rate)
        emu = open_emu(path, sample_rate)
        yield emu
      ensure
        GmeLib.gme_delete(emu) if emu
      end

      def with_info(emu, subtune_index)
        info_ptr = FFI::MemoryPointer.new(:pointer)
        err = GmeLib.gme_track_info(emu, info_ptr, subtune_index)
        raise Error, err if err
        begin
          yield GmeInfo.new(info_ptr.read_pointer)
        ensure
          GmeLib.gme_free_info(info_ptr.read_pointer)
        end
      end

      def presence(str) = str.nil? || str.empty? ? nil : str
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/gme_backend_test.rb`
Expected: `7 runs ... 0 failures, 0 errors`
Note: if `test_open_bogus_file_raises` fails because gme somehow accepts the jpg, that is a real finding — do not weaken the test; check the error path.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/backends/gme.rb test/gme_backend_test.rb
git commit -m "feat: GmeBackend FFI binding (nsf/gbs/hes/spc/vgm + subtunes)"
```

---

### Task 7: OpenmptBackend (libopenmpt FFI)

Prerequisite: `brew install libopenmpt`.

**Files:**
- Create: `lib/rubyplayer/backends/openmpt.rb`
- Test: `test/openmpt_backend_test.rb`
- Do NOT require from `lib/rubyplayer.rb` (loaded lazily by the Registry).

**Interfaces:**
- Consumes: nothing (parallel to Task 6).
- Produces: `RubyPlayer::Backends::Openmpt` with the EXACT same interface shape as `Gme` (Task 6): `#name` ⇒ `"openmpt"`, `#track_count(path)` ⇒ always `1`, `#metadata(path, subtune_index)`, `#open(path, subtune_index, sample_rate:)` ⇒ Handle (`#read/#seek/#position_ms/#duration_ms/#close`), `Openmpt::Error`.

- [ ] **Step 1: Write the failing test**

`test/openmpt_backend_test.rb`:
```ruby
require "test_helper"
require "rubyplayer/backends/openmpt"

class OpenmptBackendTest < Minitest::Test
  def setup
    @mpt = RubyPlayer::Backends::Openmpt.new
  end

  def test_track_count_is_one
    assert_equal 1, @mpt.track_count(File.join(FIXTURES, "space-debris.mod"))
  end

  def test_metadata_shape
    meta = @mpt.metadata(File.join(FIXTURES, "space-debris.mod"), 0)
    assert_kind_of String, meta[:title]
    refute_empty meta[:title]
    assert_equal "mod", meta[:format]
    assert_operator meta[:duration_ms], :>, 10_000 # space debris is minutes long
  end

  def test_title_falls_back_to_filename
    # .xm/.s3m usually carry titles; if empty, basename is used — exercise via jpg? No:
    # jpg won't load. Instead assert the fallback logic directly on a real file whose
    # title may or may not be set: the contract is "title is never nil/empty".
    %w[deadlock.xm leynos-2nd-pm.s3m].each do |f|
      meta = @mpt.metadata(File.join(FIXTURES, f), 0)
      refute_nil meta[:title]
      refute_empty meta[:title]
    end
  end

  def test_decode_produces_bounded_float_pcm
    h = @mpt.open(File.join(FIXTURES, "deadlock.xm"), 0, sample_rate: 48_000)
    data = h.read(1024)
    assert_equal 1024 * 2 * 4, data.bytesize
    floats = data.unpack("e*")
    assert(floats.all? { |f| f >= -1.0 && f <= 1.0 })
    h.close
  end

  def test_seek_and_position
    h = @mpt.open(File.join(FIXTURES, "space-debris.mod"), 0, sample_rate: 48_000)
    assert h.seek(10_000)
    assert_in_delta 10_000, h.position_ms, 1_000
    h.close
  end

  def test_open_bogus_file_raises
    assert_raises(RubyPlayer::Backends::Openmpt::Error) do
      @mpt.open(File.join(FIXTURES, "warrior.jpg"), 0, sample_rate: 48_000)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/openmpt_backend_test.rb`
Expected: FAIL — `cannot load such file -- rubyplayer/backends/openmpt`

- [ ] **Step 3: Implement**

`lib/rubyplayer/backends/openmpt.rb`:
```ruby
require "ffi"

module RubyPlayer
  module Backends
    module OpenmptLib
      extend FFI::Library
      ffi_lib ["openmpt", "libopenmpt.dylib", "/opt/homebrew/lib/libopenmpt.dylib"]

      attach_function :openmpt_module_create_from_memory2,
                      [:pointer, :size_t, :pointer, :pointer, :pointer, :pointer,
                       :pointer, :pointer, :pointer], :pointer
      attach_function :openmpt_module_destroy, [:pointer], :void
      attach_function :openmpt_module_read_interleaved_float_stereo,
                      [:pointer, :int32, :size_t, :pointer], :size_t, blocking: true
      attach_function :openmpt_module_get_duration_seconds, [:pointer], :double
      attach_function :openmpt_module_set_position_seconds, [:pointer, :double], :double
      attach_function :openmpt_module_get_position_seconds, [:pointer], :double
      attach_function :openmpt_module_get_metadata, [:pointer, :string], :pointer
      attach_function :openmpt_free_string, [:pointer], :void
    end

    class Openmpt
      class Error < StandardError; end

      def name = "openmpt"

      def track_count(_path) = 1 # tracker modules are single-song

      def metadata(path, _subtune_index)
        with_mod(path) do |mod|
          {
            title: presence(read_meta(mod, "title")) || File.basename(path, ".*"),
            album: nil,
            artist: presence(read_meta(mod, "artist")),
            composer: presence(read_meta(mod, "artist")),
            track_number: nil,
            duration_ms: (OpenmptLib.openmpt_module_get_duration_seconds(mod) * 1000).round,
            format: File.extname(path).delete_prefix(".").downcase,
          }
        end
      end

      def open(path, _subtune_index, sample_rate:)
        Handle.new(create_mod(path), sample_rate)
      end

      class Handle
        attr_reader :duration_ms

        def initialize(mod, sample_rate)
          @mod = mod
          @sample_rate = sample_rate
          @duration_ms = (OpenmptLib.openmpt_module_get_duration_seconds(mod) * 1000).round
        end

        # openmpt renders float natively — read_bytes is already our canonical format.
        def read(frames)
          return nil if @mod.nil?
          if @buf.nil? || @buf_frames != frames
            @buf = FFI::MemoryPointer.new(:float, frames * 2)
            @buf_frames = frames
          end
          n = OpenmptLib.openmpt_module_read_interleaved_float_stereo(@mod, @sample_rate, frames, @buf)
          return nil if n.zero? # end of module
          @buf.read_bytes(n * 2 * 4)
        end

        def seek(ms)
          OpenmptLib.openmpt_module_set_position_seconds(@mod, ms / 1000.0)
          true
        end

        def position_ms
          (OpenmptLib.openmpt_module_get_position_seconds(@mod) * 1000).round
        end

        def close
          OpenmptLib.openmpt_module_destroy(@mod) if @mod
          @mod = nil
        end
      end

      private

      def create_mod(path)
        data = File.binread(path)
        ptr = FFI::MemoryPointer.new(:char, data.bytesize)
        ptr.put_bytes(0, data)
        mod = OpenmptLib.openmpt_module_create_from_memory2(
          ptr, data.bytesize, nil, nil, nil, nil, nil, nil, nil
        )
        raise Error, "libopenmpt could not load #{path}" if mod.null?
        mod
      end

      def with_mod(path)
        mod = create_mod(path)
        yield mod
      ensure
        OpenmptLib.openmpt_module_destroy(mod) if mod && !mod.null?
      end

      def read_meta(mod, key)
        ptr = OpenmptLib.openmpt_module_get_metadata(mod, key)
        return nil if ptr.null?
        str = ptr.read_string.dup.force_encoding("UTF-8")
        OpenmptLib.openmpt_free_string(ptr)
        str
      end

      def presence(str) = str.nil? || str.empty? ? nil : str
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/openmpt_backend_test.rb`
Expected: `6 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer/backends/openmpt.rb test/openmpt_backend_test.rb
git commit -m "feat: OpenmptBackend FFI binding (mod/xm/s3m/it trackers)"
```

---

### Task 8: BackendRegistry

**Files:**
- Create: `lib/rubyplayer/backends/registry.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/backends/registry"` — the registry itself is pure data; it lazily requires the FFI backends only when one is instantiated)
- Test: `test/registry_test.rb`

**Interfaces:**
- Consumes: `Backends::Gme` / `Backends::Openmpt` (lazily).
- Produces:
  - `RubyPlayer::Backends::Registry.new(overrides = {})` — `overrides` is the config table `config["backends"]` mapping extension (with or without dot) to `"gme"`/`"openmpt"`.
  - `#supported?(path)` ⇒ bool (by extension, case-insensitive).
  - `#multitrack?(path)` ⇒ bool (formats that can contain multiple subtunes).
  - `#backend_name_for(path)` ⇒ `:gme` | `:openmpt` | nil.
  - `#backend_for(path)` ⇒ memoized backend instance or nil.

- [ ] **Step 1: Write the failing test**

`test/registry_test.rb`:
```ruby
require "test_helper"

class RegistryTest < Minitest::Test
  def setup
    @reg = RubyPlayer::Backends::Registry.new
  end

  def test_supported_extensions
    assert @reg.supported?("/x/a.nsf")
    assert @reg.supported?("/x/a.MOD") # case-insensitive
    assert @reg.supported?("/x/a.spc")
    refute @reg.supported?("/x/warrior.jpg")
    refute @reg.supported?("/x/noext")
  end

  def test_backend_names
    assert_equal :gme, @reg.backend_name_for("/x/a.vgm")
    assert_equal :openmpt, @reg.backend_name_for("/x/a.xm")
    assert_nil @reg.backend_name_for("/x/a.jpg")
  end

  def test_multitrack_detection
    assert @reg.multitrack?("/x/a.nsf")
    assert @reg.multitrack?("/x/a.gbs")
    assert @reg.multitrack?("/x/a.hes")
    refute @reg.multitrack?("/x/a.spc")
    refute @reg.multitrack?("/x/a.mod")
  end

  def test_config_overrides
    reg = RubyPlayer::Backends::Registry.new({ "vgm" => "openmpt", ".weird" => "gme" })
    assert_equal :openmpt, reg.backend_name_for("/x/a.vgm")
    assert_equal :gme, reg.backend_name_for("/x/a.weird")
  end

  def test_backend_for_returns_memoized_instance
    a = @reg.backend_for("/x/a.mod")
    b = @reg.backend_for("/x/b.xm")
    assert_same a, b
    assert_equal "openmpt", a.name
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/registry_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::Backends`

- [ ] **Step 3: Implement**

`lib/rubyplayer/backends/registry.rb`:
```ruby
module RubyPlayer
  module Backends
    class Registry
      GME_EXTS = %w[.nsf .nsfe .gbs .hes .sap .spc .vgm .vgz .gym .ay .kss].freeze
      OPENMPT_EXTS = %w[.mod .xm .it .s3m .mptm .mtm .669 .med .okt .stm .ult
                        .amf .dsm .far .ptm].freeze
      # Formats whose single file can hold many subtunes.
      MULTITRACK_EXTS = %w[.nsf .nsfe .gbs .hes .sap .ay .kss].freeze

      def initialize(overrides = {})
        @map = {}
        GME_EXTS.each { |e| @map[e] = :gme }
        OPENMPT_EXTS.each { |e| @map[e] = :openmpt }
        (overrides || {}).each do |ext, name|
          e = ext.start_with?(".") ? ext.downcase : ".#{ext.downcase}"
          @map[e] = name.to_sym
        end
        @instances = {}
      end

      def supported?(path) = @map.key?(ext_of(path))
      def multitrack?(path) = MULTITRACK_EXTS.include?(ext_of(path))
      def backend_name_for(path) = @map[ext_of(path)]

      def backend_for(path)
        case backend_name_for(path)
        when :gme
          @instances[:gme] ||= begin
            require_relative "gme"
            Gme.new
          end
        when :openmpt
          @instances[:openmpt] ||= begin
            require_relative "openmpt"
            Openmpt.new
          end
        end
      end

      private

      def ext_of(path) = File.extname(path).downcase
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/backends/registry"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/registry_test.rb`
Expected: `5 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/backends/registry.rb test/registry_test.rb
git commit -m "feat: BackendRegistry with extension map, multitrack detection, config overrides"
```

---

### Task 9: Scanner (fast reconcile pass: walk + diff)

The reconcile pass only `stat`s — it never opens music files. It produces the work list
for Task 10's extractor pool and flags vanished rows as missing.

**Files:**
- Create: `lib/rubyplayer/scanner.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/scanner"`)
- Test: `test/scanner_test.rb`

**Interfaces:**
- Consumes: `Library#upsert_folder`, `Library#db_paths_under`, `Library#mark_missing` (Task 4); `Registry#supported?`, `Registry#multitrack?` (Task 8).
- Produces:
  - `RubyPlayer::WorkItem` — `Struct.new(:path, :parent_folder_id, :status, keyword_init: true)`; `status` is `:new` or `:changed`.
  - `RubyPlayer::Scanner.new(library:, registry:)`
  - `#reconcile(root)` ⇒ `[WorkItem]`. Side effects: upserts `dir` folder rows for every directory seen; marks DB tracks/folders under `root` that were NOT seen as `missing=1`. `root` may be a directory or a single supported file. Hidden entries (leading `.`) are skipped. Unreadable directories are skipped, not fatal.

- [ ] **Step 1: Write the failing test**

`test/scanner_test.rb`:
```ruby
require "test_helper"
require "tmpdir"
require "fileutils"

class ScannerTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @music = File.join(@tmp, "music")
    FileUtils.mkdir_p(File.join(@music, "sega"))
    # reconcile only stats files, so empty files with the right extensions suffice
    @mod = write_file("sega/a.mod", "x" * 100)
    @nsf = write_file("multi.nsf", "y" * 200)
    write_file("warrior.jpg", "not music")
    write_file(".hidden.mod", "skipped")
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @scanner = RubyPlayer::Scanner.new(library: @lib, registry: RubyPlayer::Backends::Registry.new)
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  def write_file(rel, content)
    path = File.join(@music, rel)
    File.write(path, content)
    path
  end

  def track_attrs(path, folder_id, stat: File.stat(path))
    { folder_id: folder_id, physical_path: path, backend: "gme", format: "mod",
      title: "t", duration_ms: 1000, file_mtime: stat.mtime.to_f, file_size: stat.size }
  end

  def test_new_files_yield_new_work_items_and_folder_rows
    work = @scanner.reconcile(@music)
    assert_equal [[@nsf, :new], [@mod, :new]].sort, work.map { |w| [w.path, w.status] }.sort
    # dir rows exist for music/ and music/sega/ (query raw: track_count still 0)
    paths = @db.read { |s| s.execute("SELECT path, kind FROM folders").map { |r| [r["path"], r["kind"]] } }
    assert_includes paths, [@music, "dir"]
    assert_includes paths, [File.join(@music, "sega"), "dir"]
  end

  def test_unchanged_files_yield_no_work
    work = @scanner.reconcile(@music)
    sega_id = @db.read { |s| s.get_first_value("SELECT id FROM folders WHERE path = ?", [File.join(@music, "sega")]) }
    @lib.upsert_track(track_attrs(@mod, sega_id))
    music_id = @db.read { |s| s.get_first_value("SELECT id FROM folders WHERE path = ?", [@music]) }
    @lib.upsert_track(track_attrs(@nsf, music_id))
    assert_empty @scanner.reconcile(@music)
  end

  def test_changed_file_yields_changed_work_item
    @scanner.reconcile(@music)
    sega_id = @db.read { |s| s.get_first_value("SELECT id FROM folders WHERE path = ?", [File.join(@music, "sega")]) }
    @lib.upsert_track(track_attrs(@mod, sega_id))
    File.write(@mod, "z" * 150) # size + mtime change
    work = @scanner.reconcile(@music)
    changed = work.find { |w| w.path == @mod }
    assert_equal :changed, changed.status
  end

  def test_vanished_files_marked_missing_not_deleted
    @scanner.reconcile(@music)
    sega_id = @db.read { |s| s.get_first_value("SELECT id FROM folders WHERE path = ?", [File.join(@music, "sega")]) }
    id = @lib.upsert_track(track_attrs(@mod, sega_id))
    File.delete(@mod)
    @scanner.reconcile(@music)
    row = @db.read { |s| s.execute("SELECT missing FROM tracks WHERE id = ?", [id]).first }
    assert_equal 1, row["missing"]
  end

  def test_multitrack_virtual_folder_not_marked_missing_on_rescan
    @scanner.reconcile(@music)
    music_id = @db.read { |s| s.get_first_value("SELECT id FROM folders WHERE path = ?", [@music]) }
    # simulate the extractor having created a multitrack virtual folder for the nsf
    stat = File.stat(@nsf)
    @lib.upsert_folder(parent_id: music_id, name: "multi.nsf", path: @nsf,
                       kind: "multitrack", mtime: stat.mtime.to_f, size: stat.size)
    @lib.upsert_track(track_attrs(@nsf, music_id))
    @scanner.reconcile(@music)
    row = @db.read { |s| s.execute("SELECT missing FROM folders WHERE path = ?", [@nsf]).first }
    assert_equal 0, row["missing"]
  end

  def test_single_file_root
    work = @scanner.reconcile(@mod)
    assert_equal [[@mod, :new]], work.map { |w| [w.path, w.status] }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/scanner_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::Scanner`

- [ ] **Step 3: Implement**

`lib/rubyplayer/scanner.rb`:
```ruby
module RubyPlayer
  WorkItem = Struct.new(:path, :parent_folder_id, :status, keyword_init: true)

  # Phase-1 scan: filesystem walk + stat diff against the DB. Fast (never opens
  # music files). Returns WorkItems for the ExtractorPool (phase 2).
  class Scanner
    def initialize(library:, registry:)
      @library = library
      @registry = registry
    end

    def reconcile(root)
      root = File.expand_path(root)
      known = @library.db_paths_under(root)
      seen_tracks = {}
      seen_folders = {}
      work = []

      if File.directory?(root)
        root_id = @library.upsert_folder(parent_id: nil, name: File.basename(root),
                                         path: root, kind: "dir")
        seen_folders[root] = true
        walk(root, root_id, known, seen_tracks, seen_folders, work)
      elsif File.file?(root) && @registry.supported?(root)
        parent = File.dirname(root)
        parent_id = @library.upsert_folder(parent_id: nil, name: File.basename(parent),
                                           path: parent, kind: "dir")
        seen_folders[parent] = true
        diff_file(root, parent_id, known, seen_tracks, seen_folders, work)
      end

      missing_track_ids = known[:tracks].reject { |p, _| seen_tracks[p] }
                                        .values.flat_map { |v| v[:ids] }
      missing_folder_ids = known[:folders].reject { |p, _| seen_folders[p] }
                                          .values.map { |v| v[:id] }
      @library.mark_missing(track_ids: missing_track_ids, folder_ids: missing_folder_ids)
      work
    end

    private

    def walk(dir, dir_id, known, seen_tracks, seen_folders, work)
      Dir.children(dir).sort.each do |name|
        next if name.start_with?(".")
        path = File.join(dir, name)
        if File.directory?(path)
          id = @library.upsert_folder(parent_id: dir_id, name: name, path: path, kind: "dir")
          seen_folders[path] = true
          walk(path, id, known, seen_tracks, seen_folders, work)
        elsif File.file?(path) && @registry.supported?(path)
          diff_file(path, dir_id, known, seen_tracks, seen_folders, work)
        end
      end
    rescue Errno::EACCES, Errno::ENOENT
      # unreadable or vanished mid-walk: skip, never fatal
    end

    def diff_file(path, parent_folder_id, known, seen_tracks, seen_folders, work)
      seen_tracks[path] = true
      # a multi-subtune file also has a virtual folder row keyed by its path
      seen_folders[path] = true if @registry.multitrack?(path)
      stat = File.stat(path)
      existing = known[:tracks][path]
      if existing.nil?
        work << WorkItem.new(path: path, parent_folder_id: parent_folder_id, status: :new)
      elsif existing[:mtime] != stat.mtime.to_f || existing[:size] != stat.size
        work << WorkItem.new(path: path, parent_folder_id: parent_folder_id, status: :changed)
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/scanner"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/scanner_test.rb`
Expected: `6 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/scanner.rb test/scanner_test.rb
git commit -m "feat: Scanner reconcile pass (walk + stat diff -> work list, missing flags)"
```

---

### Task 10: ExtractorPool (bounded metadata worker pool)

Phase-2 scan: opens new/changed files via FFI backends on N worker threads (FFI releases
the GVL, so this is truly parallel), writes rows through the single-writer Database, and
recomputes folder counts when done.

**Files:**
- Create: `lib/rubyplayer/extractor_pool.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/extractor_pool"`)
- Test: `test/extractor_pool_test.rb` (integration: uses real fixtures + libgme/libopenmpt)

**Interfaces:**
- Consumes: `WorkItem` (Task 9), `Library#upsert_track/#upsert_folder/#recompute_counts!` (Task 4), `Registry#backend_for/#multitrack?/#backend_name_for` (Task 8). Optional `event_bus:` — any object responding to `publish(type, **payload)`; nil is fine (Task 15 provides the real one).
- Produces:
  - `RubyPlayer::ExtractorPool.new(library:, registry:, thread_count: 0, event_bus: nil)` — `thread_count` 0 ⇒ `Etc.nprocessors`.
  - `#process(work_items)` ⇒ `{processed: n, errored: n}`; blocks until done. Publishes `:scan_progress` per item and `:scan_complete` at the end. A file that fails to open is recorded as an `errored=1` track row (title = filename) — never raises out.
  - Multi-subtune files produce one `kind="multitrack"` folder row (path = the file) + one track row per subtune; everything else produces a single track row under the parent dir folder.

- [ ] **Step 1: Write the failing test**

`test/extractor_pool_test.rb`:
```ruby
require "test_helper"
require "tmpdir"
require "fileutils"

class ExtractorPoolTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @music = File.join(@tmp, "music")
    FileUtils.mkdir_p(@music)
    FileUtils.cp(File.join(FIXTURES, "space-debris.mod"), @music)
    FileUtils.cp(File.join(FIXTURES, "mega-man-2.nsf"), @music)
    File.write(File.join(@music, "corrupt.mod"), "\x00" * 64) # bogus module
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @reg = RubyPlayer::Backends::Registry.new
    @scanner = RubyPlayer::Scanner.new(library: @lib, registry: @reg)
    @pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: @reg, thread_count: 2)
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  def test_full_scan_pipeline
    work = @scanner.reconcile(@music)
    result = @pool.process(work)
    assert_equal 3, result[:processed]
    assert_equal 1, result[:errored]

    # the mod became a single track with metadata
    mod = @db.read { |s| s.execute("SELECT * FROM tracks WHERE physical_path LIKE '%space-debris.mod'").first }
    assert_equal "openmpt", mod["backend"]
    assert_operator mod["duration_ms"], :>, 10_000
    refute_nil mod["file_mtime"]

    # the nsf became a multitrack virtual folder with N subtune tracks
    nsf_folder = @db.read { |s| s.execute("SELECT * FROM folders WHERE kind = 'multitrack'").first }
    refute_nil nsf_folder
    subtunes = @db.read { |s| s.get_first_value("SELECT COUNT(*) FROM tracks WHERE folder_id = ?", [nsf_folder["id"]]) }
    assert_operator subtunes, :>, 1

    # the corrupt file is flagged errored, not raised
    bad = @db.read { |s| s.execute("SELECT * FROM tracks WHERE physical_path LIKE '%corrupt.mod'").first }
    assert_equal 1, bad["errored"]

    # counts were recomputed and the root is visible
    roots = @lib.roots
    assert_equal 1, roots.size
    assert_operator roots.first["track_count"], :>, 2

    # idempotency: a second reconcile finds nothing to do
    assert_empty @scanner.reconcile(@music)
  end

  def test_progress_events_published
    events = []
    bus = Object.new
    bus.define_singleton_method(:publish) { |type, **payload| events << [type, payload] }
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: @reg, thread_count: 2, event_bus: bus)
    pool.process(@scanner.reconcile(@music))
    assert_equal 3, events.count { |t, _| t == :scan_progress }
    assert_equal 1, events.count { |t, _| t == :scan_complete }
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/extractor_pool_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::ExtractorPool`

- [ ] **Step 3: Implement**

`lib/rubyplayer/extractor_pool.rb`:
```ruby
require "etc"

module RubyPlayer
  # Phase-2 scan: bounded worker pool extracting metadata via FFI backends.
  # Parallelism is real because FFI calls release the GVL.
  class ExtractorPool
    def initialize(library:, registry:, thread_count: 0, event_bus: nil)
      @library = library
      @registry = registry
      @thread_count = thread_count.positive? ? thread_count : Etc.nprocessors
      @event_bus = event_bus
    end

    def process(work_items)
      return { processed: 0, errored: 0 } if work_items.empty?
      queue = Thread::Queue.new
      work_items.each { |w| queue << w }
      @thread_count.times { queue << :done }
      errored = 0
      mutex = Mutex.new

      threads = Array.new(@thread_count) do
        Thread.new do
          while (item = queue.pop) != :done
            ok = extract(item)
            mutex.synchronize { errored += 1 unless ok }
            @event_bus&.publish(:scan_progress, path: item.path)
          end
        end
      end
      threads.each(&:join)

      @library.recompute_counts!
      result = { processed: work_items.size, errored: errored }
      @event_bus&.publish(:scan_complete, **result)
      result
    end

    private

    def extract(item)
      stat = File.stat(item.path)
      backend = @registry.backend_for(item.path)
      count = @registry.multitrack?(item.path) ? backend.track_count(item.path) : 1
      if count > 1
        folder_id = @library.upsert_folder(parent_id: item.parent_folder_id,
                                           name: File.basename(item.path),
                                           path: item.path, kind: "multitrack",
                                           mtime: stat.mtime.to_f, size: stat.size)
        count.times do |i|
          upsert(item.path, folder_id, i, backend, backend.metadata(item.path, i), stat)
        end
      else
        upsert(item.path, item.parent_folder_id, 0, backend,
               backend.metadata(item.path, 0), stat)
      end
      true
    rescue StandardError
      # Undecodable file: flag it, keep the pool alive.
      @library.upsert_track(
        folder_id: item.parent_folder_id, physical_path: item.path,
        backend: @registry.backend_name_for(item.path).to_s,
        format: File.extname(item.path).delete_prefix(".").downcase,
        title: File.basename(item.path), errored: 1,
        file_mtime: stat&.mtime&.to_f, file_size: stat&.size
      )
      false
    end

    def upsert(path, folder_id, subtune, backend, meta, stat)
      @library.upsert_track(
        folder_id: folder_id, physical_path: path, subtune_index: subtune,
        backend: backend.name, format: meta[:format], title: meta[:title],
        album: meta[:album], artist: meta[:artist], composer: meta[:composer],
        track_number: meta[:track_number], duration_ms: meta[:duration_ms],
        file_mtime: stat.mtime.to_f, file_size: stat.size
      )
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/extractor_pool"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/extractor_pool_test.rb`
Expected: `2 runs ... 0 failures, 0 errors`
Note: `stat` in the rescue is the local from the begin body — if `File.stat` itself raised, it is nil and the `&.` calls store NULLs, which is correct.

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/extractor_pool.rb test/extractor_pool_test.rb
git commit -m "feat: ExtractorPool - parallel metadata extraction with errored-file flagging"
```

---

### Task 11: PlayQueue (queue + undo/redo)

Pure domain object, no I/O. The PlaybackEngine (Task 14) owns the single authoritative
instance. Undo snapshots capture MANUAL queueing operations only — automatic advancement
when a track ends is not undoable (matches the spec: "any time the user manually adds or
removes tracks").

**Files:**
- Create: `lib/rubyplayer/play_queue.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/play_queue"`)
- Test: `test/play_queue_test.rb`

**Interfaces:**
- Consumes: `Track` (Task 4) — but works with any objects; it never inspects items.
- Produces `RubyPlayer::PlayQueue.new(undo_depth: 10)`:
  - `#items` ⇒ frozen dup Array (head = currently playing when engine is playing).
  - `#first`, `#size`, `#empty?`
  - `#enqueue_now(tracks, playing: false)` — if `playing`, discards the interrupted head; inserts `tracks` at the front. (Engine restarts decode at the new head.)
  - `#enqueue_front(tracks, playing: false)` — inserts at index 1 when `playing` (just after current), else at 0.
  - `#enqueue_end(tracks)` — appends.
  - `#remove_at(index)` ⇒ removed item or nil.
  - `#advance!` ⇒ new head (or nil) after dropping the old head. NOT undoable, no snapshot.
  - `#undo` / `#redo` ⇒ bool. Manual mutators snapshot before mutating (max `undo_depth`); a new manual mutation clears the redo stack.
  - `#on_change { }` — single callback invoked after every mutation (including advance!/undo/redo). The engine wires this to an EventBus publish.

- [ ] **Step 1: Write the failing test**

`test/play_queue_test.rb`:
```ruby
require "test_helper"

class PlayQueueTest < Minitest::Test
  def setup
    @q = RubyPlayer::PlayQueue.new(undo_depth: 3)
  end

  def test_enqueue_end_and_advance
    @q.enqueue_end(%w[a b c])
    assert_equal "a", @q.first
    assert_equal "b", @q.advance!
    assert_equal %w[b c], @q.items
  end

  def test_enqueue_front_respects_playing_head
    @q.enqueue_end(%w[a b])
    @q.enqueue_front(%w[x], playing: true)
    assert_equal %w[a x b], @q.items
    @q.enqueue_front(%w[y], playing: false)
    assert_equal %w[y a x b], @q.items
  end

  def test_enqueue_now_replaces_playing_head
    @q.enqueue_end(%w[a b])
    @q.enqueue_now(%w[x], playing: true)
    assert_equal %w[x b], @q.items # 'a' was interrupted and discarded
    @q.enqueue_now(%w[y], playing: false)
    assert_equal %w[y x b], @q.items # nothing playing: nothing discarded
  end

  def test_undo_redo_roundtrip
    @q.enqueue_end(%w[a])
    @q.enqueue_end(%w[b])
    assert @q.undo
    assert_equal %w[a], @q.items
    assert @q.redo
    assert_equal %w[a b], @q.items
    refute @q.redo
  end

  def test_new_mutation_clears_redo
    @q.enqueue_end(%w[a])
    @q.enqueue_end(%w[b])
    @q.undo
    @q.enqueue_end(%w[c])
    refute @q.redo
    assert_equal %w[a c], @q.items
  end

  def test_undo_depth_limited
    5.times { |i| @q.enqueue_end([i.to_s]) }
    undos = 0
    undos += 1 while @q.undo
    assert_equal 3, undos # depth 3
  end

  def test_advance_is_not_undoable
    @q.enqueue_end(%w[a b])
    @q.advance!
    @q.undo # undoes the enqueue_end, not the advance
    assert_empty @q.items
  end

  def test_remove_at_and_change_callback
    changes = 0
    @q.on_change { changes += 1 }
    @q.enqueue_end(%w[a b])
    assert_equal "b", @q.remove_at(1)
    assert_nil @q.remove_at(9)
    assert_equal %w[a], @q.items
    assert_equal 2, changes # enqueue + successful remove (failed remove: no change)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/play_queue_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::PlayQueue`

- [ ] **Step 3: Implement**

`lib/rubyplayer/play_queue.rb`:
```ruby
module RubyPlayer
  # The playback queue. Head of the list = currently playing track (when the
  # engine is playing). Named PlayQueue because ::Queue is Thread::Queue.
  class PlayQueue
    def initialize(undo_depth: 10)
      @items = []
      @undo_depth = undo_depth
      @undo_stack = []
      @redo_stack = []
      @on_change = nil
    end

    def items = @items.dup
    def first = @items.first
    def size = @items.size
    def empty? = @items.empty?
    def on_change(&blk) = @on_change = blk

    def enqueue_now(tracks, playing: false)
      snapshot!
      @items.shift if playing # the interrupted track does not come back
      @items = tracks + @items
      changed!
    end

    def enqueue_front(tracks, playing: false)
      snapshot!
      @items.insert(playing ? 1 : 0, *tracks)
      changed!
    end

    def enqueue_end(tracks)
      snapshot!
      @items.concat(tracks)
      changed!
    end

    def remove_at(index)
      return nil if index.negative? || index >= @items.size
      snapshot!
      removed = @items.delete_at(index)
      changed!
      removed
    end

    # Automatic advancement (track ended / skip): drops the head, returns the
    # new head. Deliberately NOT undoable.
    def advance!
      @items.shift
      changed!
      @items.first
    end

    def undo
      return false if @undo_stack.empty?
      @redo_stack.push(@items.dup)
      @items = @undo_stack.pop
      changed!
      true
    end

    def redo
      return false if @redo_stack.empty?
      @undo_stack.push(@items.dup)
      @items = @redo_stack.pop
      changed!
      true
    end

    private

    def snapshot!
      @undo_stack.push(@items.dup)
      @undo_stack.shift while @undo_stack.size > @undo_depth
      @redo_stack.clear
    end

    def changed! = @on_change&.call
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/play_queue"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/play_queue_test.rb`
Expected: `8 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/play_queue.rb test/play_queue_test.rb
git commit -m "feat: PlayQueue with snapshot undo/redo and change callback"
```

---

### Task 12: Template (safe format-string evaluator)

Parses config format strings like `"{album} {track_number} {title} {duration} {artist?} {rating}"`.
Whitelisted fields only; unknown fields render as empty; NEVER uses eval. Hot-reload works
because the panes rebuild their Template when ConfigStore reports a change (Task 20).

**Files:**
- Create: `lib/rubyplayer/template.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/template"`)
- Test: `test/template_test.rb`

**Interfaces:**
- Consumes: `Track` (Task 4).
- Produces `RubyPlayer::Template.new(format_string, star_glyph: "★")`:
  - `#render(track, album_artist: nil)` ⇒ String.
  - Fields: `{title}` `{album}` `{artist}` `{composer}` `{format}` — raw strings ("" if nil); `{track_number}` — `"%02d"` ("" if nil); `{duration}` — `duration_ms` as `M:SS` ("" if nil); `{rating}` — star glyph repeated `rating` times ("" if nil); `{artist?}` — artist only when it differs from `album_artist`.
  - Unknown `{whatever}` ⇒ "". Runs of whitespace from empty fields collapse to one space; result is stripped.

- [ ] **Step 1: Write the failing test**

`test/template_test.rb`:
```ruby
require "test_helper"

class TemplateTest < Minitest::Test
  def track(**over)
    RubyPlayer::Track.new(**{ title: "Flash Man", album: "Mega Man 2", artist: "Capcom",
                              track_number: 7, duration_ms: 125_000, rating: 4 }.merge(over))
  end

  def test_basic_render
    t = RubyPlayer::Template.new("{track_number} {title} {duration}")
    assert_equal "07 Flash Man 2:05", t.render(track)
  end

  def test_rating_renders_stars
    t = RubyPlayer::Template.new("{rating}")
    assert_equal "★★★★", t.render(track)
    assert_equal "", t.render(track(rating: nil))
  end

  def test_conditional_artist
    t = RubyPlayer::Template.new("{title} {artist?}")
    assert_equal "Flash Man Capcom", t.render(track, album_artist: "Konami")
    assert_equal "Flash Man", t.render(track, album_artist: "Capcom")
  end

  def test_unknown_field_renders_empty_and_never_evals
    t = RubyPlayer::Template.new("{title} {system('rm -rf /')} {nope}")
    assert_equal "Flash Man", t.render(track)
  end

  def test_nil_fields_collapse_whitespace
    t = RubyPlayer::Template.new("{album} {track_number} {title}")
    assert_equal "Flash Man", t.render(track(album: nil, track_number: nil))
  end

  def test_duration_formatting
    t = RubyPlayer::Template.new("{duration}")
    assert_equal "0:05", t.render(track(duration_ms: 5_400))
    assert_equal "10:00", t.render(track(duration_ms: 600_000))
    assert_equal "", t.render(track(duration_ms: nil))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/template_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::Template`

- [ ] **Step 3: Implement**

`lib/rubyplayer/template.rb`:
```ruby
module RubyPlayer
  # Safe interpolation of track-display format strings from config.
  # Whitelist only — a config typo or hostile string can never execute code.
  class Template
    TOKEN = /\{([a-z_]+\??)\}/

    def initialize(format_string, star_glyph: "★")
      @star = star_glyph
      # Alternating literal / field parts, parsed once.
      @parts = format_string.to_s.split(TOKEN).each_with_index.map do |part, i|
        i.odd? ? { field: part } : { literal: part }
      end
    end

    def render(track, album_artist: nil)
      out = @parts.map do |part|
        part.key?(:literal) ? part[:literal] : field_value(part[:field], track, album_artist)
      end.join
      out.gsub(/\s+/, " ").strip
    end

    private

    def field_value(field, track, album_artist)
      case field
      when "title"        then track.title.to_s
      when "album"        then track.album.to_s
      when "artist"       then track.artist.to_s
      when "artist?"      then track.artist == album_artist ? "" : track.artist.to_s
      when "composer"     then track.composer.to_s
      when "format"       then track.format.to_s
      when "track_number" then track.track_number ? format("%02d", track.track_number) : ""
      when "duration"     then duration(track.duration_ms)
      when "rating"       then track.rating ? @star * track.rating : ""
      else "" # unknown field: render nothing, never fail
      end
    end

    def duration(ms)
      return "" unless ms
      total = ms / 1000
      format("%d:%02d", total / 60, total % 60)
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/template"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/template_test.rb`
Expected: `6 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/template.rb test/template_test.rb
git commit -m "feat: Template - whitelisted format-string evaluator (no eval)"
```

---

### Task 13: Keymap

Maps normalized key names to action symbols. Defaults live here; the TOML `[keymap.global]`,
`[keymap.library]`, `[keymap.tracks]` tables override them. The App (Task 20) is responsible
for normalizing tty-reader key events into these string names: `"up" "down" "left" "right"
"tab" "space" "enter" "escape" "backspace"`, printable chars as themselves (case-sensitive),
and control chords as `"ctrl_x"`.

Default map (terminal-reality substitutions per spec §9: no Cmd combos, no ctrl_z):
`u`=undo, `ctrl_r`=redo, sorts are UPPERCASE pane-local keys so lowercase globals stay free.

**Files:**
- Create: `lib/rubyplayer/keymap.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/keymap"`)
- Test: `test/keymap_test.rb`

**Interfaces:**
- Consumes: `config["keymap"]` Hash (Task 2).
- Produces `RubyPlayer::Keymap.new(config_keymap = {})`:
  - `#action_for(key, pane:)` ⇒ Symbol or nil. `pane` is `:library` or `:tracks`. Pane-local bindings win over global.
  - `#bindings_for(pane)` ⇒ ordered `[[key, action], ...]` (pane-local then global, deduped by key) — feeds the hotkey line (Task 19).

- [ ] **Step 1: Write the failing test**

`test/keymap_test.rb`:
```ruby
require "test_helper"

class KeymapTest < Minitest::Test
  def test_global_defaults
    k = RubyPlayer::Keymap.new
    assert_equal :toggle_play, k.action_for("space", pane: :library)
    assert_equal :cycle_pane, k.action_for("tab", pane: :tracks)
    assert_equal :play_now, k.action_for("enter", pane: :tracks)
    assert_equal :enqueue_end, k.action_for("n", pane: :library)
    assert_equal :undo, k.action_for("u", pane: :library)
    assert_equal :redo, k.action_for("ctrl_r", pane: :library)
    assert_equal :rate_3, k.action_for("3", pane: :tracks)
    assert_equal :quit, k.action_for("ctrl_c", pane: :library)
  end

  def test_pane_local_beats_global_and_case_matters
    k = RubyPlayer::Keymap.new
    assert_equal :sort_number, k.action_for("N", pane: :tracks) # uppercase: pane sort
    assert_equal :enqueue_end, k.action_for("n", pane: :tracks) # lowercase: global
    assert_nil k.action_for("N", pane: :library) # sorts don't exist in library pane
    assert_equal :nav_up, k.action_for("up", pane: :library)
  end

  def test_config_overrides
    k = RubyPlayer::Keymap.new({ "global" => { "x" => "quit" },
                                 "tracks" => { "z" => "toggle_group" } })
    assert_equal :quit, k.action_for("x", pane: :library)
    assert_equal :toggle_group, k.action_for("z", pane: :tracks)
    assert_nil k.action_for("z", pane: :library)
    assert_equal :toggle_play, k.action_for("space", pane: :library) # defaults survive
  end

  def test_bindings_for_lists_pane_then_global
    k = RubyPlayer::Keymap.new
    keys = k.bindings_for(:tracks).map(&:first)
    assert keys.index("G") < keys.index("space"), "pane-local keys come first"
  end

  def test_unknown_key_is_nil
    assert_nil RubyPlayer::Keymap.new.action_for("f9", pane: :library)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/keymap_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::Keymap`

- [ ] **Step 3: Implement**

`lib/rubyplayer/keymap.rb`:
```ruby
module RubyPlayer
  class Keymap
    DEFAULTS = {
      "global" => {
        "tab" => "cycle_pane",
        "space" => "toggle_play",
        "enter" => "play_now",
        "q" => "enqueue_front",
        "n" => "enqueue_end",
        "p" => "select_queue",
        "u" => "undo",
        "ctrl_r" => "redo",
        "s" => "toggle_skip_disliked",
        "a" => "add_path",
        "0" => "rate_0", "1" => "rate_1", "2" => "rate_2", "3" => "rate_3",
        "4" => "rate_4", "5" => "rate_5", "6" => "rate_6",
        "ctrl_c" => "quit",
      },
      "library" => {
        "up" => "nav_up", "down" => "nav_down",
        "left" => "collapse", "right" => "expand",
      },
      "tracks" => {
        "up" => "nav_up", "down" => "nav_down",
        "G" => "toggle_group",
        "T" => "sort_title", "N" => "sort_number", "A" => "sort_artist",
      },
    }.freeze

    def initialize(config_keymap = {})
      @map = DEFAULTS.to_h do |scope, keys|
        [scope, keys.merge((config_keymap || {})[scope] || {})]
      end
    end

    def action_for(key, pane:)
      action = @map[pane.to_s]&.[](key) || @map["global"][key]
      action&.to_sym
    end

    def bindings_for(pane)
      local = @map[pane.to_s] || {}
      seen = {}
      (local.to_a + @map["global"].to_a).filter_map do |key, action|
        next if seen[key]
        seen[key] = true
        [key, action.to_sym]
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/keymap"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/keymap_test.rb`
Expected: `5 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/keymap.rb test/keymap_test.rb
git commit -m "feat: Keymap with TOML overrides and pane-over-global precedence"
```

---

### Task 14: LevelTap + PlaybackEngine (decoder thread)

The heart of playback. The engine owns: the authoritative PlayQueue, the decoder thread,
the AudioOutput, the LevelTap (EQ), history recording, and the skip-rated-1 rule. The UI
NEVER touches audio — it calls engine methods (commands in); the engine publishes events
(events out) to any object responding to `publish(type, **payload)` (the real EventBus
arrives in Task 15; tests use a recording fake).

Add one config default in this task: `"library" => { "history_min_seconds_unknown" => 30 }`
(history rule when a track's duration is unknown: record if ≥ this many seconds played).
Add it to `DEFAULTS["library"]` in `lib/rubyplayer/config.rb`.

**Files:**
- Create: `lib/rubyplayer/level_tap.rb`, `lib/rubyplayer/playback_engine.rb`
- Modify: `lib/rubyplayer/config.rb` (the one new default above)
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/level_tap"` only — playback_engine requires audio_output, so it is loaded explicitly like Task 5)
- Test: `test/level_tap_test.rb`, `test/playback_engine_test.rb` (integration: fixtures + null audio device)

**Interfaces:**
- Consumes: `AudioOutput` (Task 5), backend Handles via `Registry#backend_for` (Tasks 6–8), `PlayQueue` (Task 11), `Library#record_history/#rating_of/#set_rating` (Task 4), `ConfigStore` (Task 2).
- Produces:
  - `RubyPlayer::LevelTap.new(bands: 16, sample_rate: 48_000, window: 512)` — `#push(frames_string)` (decoder thread), `#levels` ⇒ Array of `bands` floats 0.0–1.0 (UI thread; thread-safe).
  - `RubyPlayer::PlaybackEngine.new(queue:, registry:, audio:, library:, event_bus:, config:)`
  - `#start` (spawns decoder thread) / `#shutdown` (stops thread, closes audio handle NOT the device).
  - UI-facing, all thread-safe: `#enqueue_now(tracks)` `#enqueue_front(tracks)` `#enqueue_end(tracks)` `#remove_at(i)` `#undo` `#redo` `#toggle_play` `#skip` `#seek(ms)` `#toggle_skip_disliked` ⇒ new bool.
  - `#queue_items` ⇒ Array snapshot; `#state` ⇒ `{track:, playing:, paused:, position_ms:, skip_disliked:}`; `#levels` ⇒ EQ array.
  - Events published: `:queue_changed`, `:track_started {track:}`, `:track_ended {track:}`, `:track_error {track:, message:}`, `:playback_state {playing:, paused:}`, `:position {position_ms:, track_id:}` (once per decoded chunk).
  - History: on track end/skip, records via `Library#record_history` iff played ≥ `history_min_percent`% of known duration, or ≥ `history_min_seconds_unknown`s when duration is unknown.

- [ ] **Step 1: Write the failing LevelTap test**

`test/level_tap_test.rb`:
```ruby
require "test_helper"

class LevelTapTest < Minitest::Test
  def sine(freq, rate, frames)
    (0...frames).flat_map do |i|
      v = 0.8 * Math.sin(2 * Math::PI * freq * i / rate.to_f)
      [v, v]
    end.pack("e*")
  end

  def test_silence_is_all_zero
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(([0.0] * 2048).pack("e*"))
    assert tap.levels.all? { |l| l < 0.01 }
  end

  def test_low_tone_excites_low_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(80, 48_000, 2048))
    levels = tap.levels
    assert_equal 8, levels.size
    assert levels.all? { |l| l >= 0.0 && l <= 1.0 }
    assert_equal 0, levels.index(levels.max), "80Hz should peak in the lowest band"
  end

  def test_high_tone_excites_high_bands_most
    tap = RubyPlayer::LevelTap.new(bands: 8, sample_rate: 48_000)
    tap.push(sine(8_000, 48_000, 2048))
    levels = tap.levels
    assert_operator levels.index(levels.max), :>=, 5
  end
end
```

- [ ] **Step 2: Run to verify failure, then implement LevelTap**

Run: `bundle exec ruby -Itest test/level_tap_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::LevelTap`

`lib/rubyplayer/level_tap.rb`:
```ruby
module RubyPlayer
  # EQ animation source: per-band magnitudes of the most recent audio, via the
  # Goertzel algorithm at log-spaced frequencies. push() runs on the decoder
  # thread; levels() on the UI thread — guarded by a mutex over a small window.
  class LevelTap
    def initialize(bands: 16, sample_rate: 48_000, window: 512)
      @bands = bands
      @rate = sample_rate
      @window = window
      @mono = Array.new(window, 0.0)
      @mutex = Mutex.new
      lo = 60.0
      hi = [12_000.0, sample_rate * 0.45].min
      step = (Math.log(hi) - Math.log(lo)) / (bands - 1)
      @freqs = Array.new(bands) { |i| Math.exp(Math.log(lo) + step * i) }
    end

    def push(frames_string)
      floats = frames_string.unpack("e*")
      mono = Array.new(floats.size / 2) { |i| (floats[i * 2] + floats[i * 2 + 1]) * 0.5 }
      @mutex.synchronize do
        @mono.concat(mono)
        excess = @mono.size - @window
        @mono.shift(excess) if excess.positive?
      end
    end

    def reset
      @mutex.synchronize { @mono.fill(0.0) }
    end

    def levels
      window = @mutex.synchronize { @mono.dup }
      @freqs.map do |freq|
        coeff = 2.0 * Math.cos(2.0 * Math::PI * freq / @rate)
        s1 = 0.0
        s2 = 0.0
        window.each do |x|
          s0 = x + coeff * s1 - s2
          s2 = s1
          s1 = s0
        end
        power = (s1 * s1) + (s2 * s2) - (coeff * s1 * s2)
        magnitude = 2.0 * Math.sqrt(power.abs) / @window
        # perceptual-ish curve so quiet content still moves the bars
        (magnitude**0.5).clamp(0.0, 1.0)
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/level_tap"`

Run: `bundle exec ruby -Itest test/level_tap_test.rb`
Expected: `3 runs ... 0 failures, 0 errors`

- [ ] **Step 3: Write the failing PlaybackEngine test**

`test/playback_engine_test.rb`:
```ruby
require "test_helper"
require "tmpdir"
require "fileutils"
require "rubyplayer/audio_output"
require "rubyplayer/playback_engine"

class PlaybackEngineTest < Minitest::Test
  FakeBus = Class.new do
    attr_reader :events
    def initialize = @events = Queue.new
    def publish(type, **payload) = @events << [type, payload]
    def all = Array.new(@events.size) { @events.pop }
  end

  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @folder = @lib.upsert_folder(parent_id: nil, name: "m", path: @tmp, kind: "dir")
    @bus = FakeBus.new
    @audio = RubyPlayer::AudioOutput.new(sample_rate: 44_100, ring_buffer_ms: 200,
                                         null_backend: true)
    @engine = RubyPlayer::PlaybackEngine.new(
      queue: RubyPlayer::PlayQueue.new, registry: RubyPlayer::Backends::Registry.new,
      audio: @audio, library: @lib, event_bus: @bus,
      config: RubyPlayer::ConfigStore.new(path: "/nonexistent.toml")
    )
    @engine.start
  end

  def teardown
    @engine.shutdown
    @audio.close
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  # Claim a tiny duration so the 5% history rule is crossed within ~0.1s of play.
  def make_track(fixture, duration_ms: 2_000, subtune: 0)
    path = File.join(FIXTURES, fixture)
    id = @lib.upsert_track(folder_id: @folder, physical_path: path,
                           subtune_index: subtune, backend: "gme", format: "gbs",
                           title: fixture, duration_ms: duration_ms)
    @lib.find_track(id)
  end

  def wait_for(timeout = 5)
    deadline = Time.now + timeout
    until (r = yield)
      flunk "timed out waiting" if Time.now > deadline
      sleep 0.02
    end
    r
  end

  def wait_for_event(type, timeout = 5)
    deadline = Time.now + timeout
    loop do
      flunk "timed out waiting for #{type}" if Time.now > deadline
      begin
        ev = @bus.events.pop(true)
        return ev if ev[0] == type
      rescue ThreadError
        sleep 0.02
      end
    end
  end

  def test_play_pause_skip_lifecycle
    t1 = make_track("shantae.gbs")
    t2 = make_track("shantae.gbs", subtune: 1)
    @engine.enqueue_now([t1, t2])
    ev = wait_for_event(:track_started)
    assert_equal t1.id, ev[1][:track].id
    wait_for { @engine.state[:position_ms].positive? }

    @engine.toggle_play # pause
    wait_for { @engine.state[:paused] }
    @engine.toggle_play # resume
    wait_for { !@engine.state[:paused] }

    @engine.skip
    ev = wait_for_event(:track_started)
    assert_equal t2.id, ev[1][:track].id

    @engine.skip # queue empty -> stops
    wait_for { !@engine.state[:playing] }
    assert_nil @engine.state[:track]
  end

  def test_history_recorded_after_5_percent
    t = make_track("shantae.gbs", duration_ms: 1_000) # 5% = 50ms
    @engine.enqueue_now([t])
    wait_for_event(:track_started)
    wait_for { @engine.state[:position_ms] > 100 }
    @engine.skip
    wait_for { @lib.history(limit: 5).size == 1 }
    assert_equal t.id, @lib.history(limit: 5).first[:track].id
  end

  def test_no_history_below_5_percent
    t = make_track("shantae.gbs", duration_ms: 3_600_000) # 5% = 3 minutes
    @engine.enqueue_now([t])
    wait_for_event(:track_started)
    @engine.skip
    sleep 0.2
    assert_empty @lib.history(limit: 5)
  end

  def test_skip_disliked_tracks
    t1 = make_track("shantae.gbs", subtune: 2)
    hated = make_track("shantae.gbs", subtune: 3)
    t3 = make_track("shantae.gbs", subtune: 4)
    @lib.set_rating(hated.id, 1)
    assert @engine.toggle_skip_disliked
    @engine.enqueue_now([t1, hated, t3])
    wait_for_event(:track_started)
    @engine.skip
    ev = wait_for_event(:track_started) # hated is skipped -> t3 starts
    assert_equal t3.id, ev[1][:track].id
  end

  def test_errored_track_is_flagged_and_skipped
    bad_path = File.join(@tmp, "bad.mod")
    File.write(bad_path, "junk")
    id = @lib.upsert_track(folder_id: @folder, physical_path: bad_path,
                           backend: "openmpt", format: "mod", title: "bad")
    good = make_track("shantae.gbs", subtune: 5)
    @engine.enqueue_now([@lib.find_track(id), good])
    ev = wait_for_event(:track_error)
    assert_equal id, ev[1][:track].id
    ev = wait_for_event(:track_started) # engine moved on
    assert_equal good.id, ev[1][:track].id
    assert_equal 1, @lib.find_track(id).errored
  end
end
```

- [ ] **Step 4: Run to verify failure**

Run: `bundle exec ruby -Itest test/playback_engine_test.rb`
Expected: FAIL — `cannot load such file -- rubyplayer/playback_engine`

- [ ] **Step 5: Implement PlaybackEngine**

First add to `DEFAULTS["library"]` in `lib/rubyplayer/config.rb`:
```ruby
      "history_min_seconds_unknown" => 30,
```

`lib/rubyplayer/playback_engine.rb`:
```ruby
require "time"
require_relative "audio_output"
require_relative "level_tap"

module RubyPlayer
  # Owns the decoder thread, the authoritative PlayQueue, and the AudioOutput.
  # UI threads call the public methods (commands in); events go out through
  # event_bus.publish. The audio device is started once and runs for the life
  # of the engine; pause/underrun emit silence.
  class PlaybackEngine
    def initialize(queue:, registry:, audio:, library:, event_bus:, config:)
      @queue = queue
      @registry = registry
      @audio = audio
      @library = library
      @bus = event_bus
      @chunk_frames = config["audio", "decode_chunk_frames"]
      @history_min_pct = config["library", "history_min_percent"]
      @history_min_unknown_ms = config["library", "history_min_seconds_unknown"] * 1000
      @level_tap = LevelTap.new(bands: config["eq", "bands"],
                                sample_rate: audio.sample_rate)
      @commands = Thread::Queue.new
      @mutex = Mutex.new # guards @queue and playback state reads from UI thread
      @playing = false
      @paused = false
      @skip_disliked = false
      @current = nil
      @handle = nil
      @pending = nil
      @frames_base = 0
      @seek_offset_ms = 0
      @started_at = nil
      @queue.on_change { @bus.publish(:queue_changed, items: @queue.items) }
    end

    def start
      @audio.start
      @thread = Thread.new { run }
      @thread.name = "decoder"
    end

    def shutdown
      @commands << :stop
      @thread&.join(5)
    end

    # ---- UI-facing commands (any thread) ----

    def enqueue_now(tracks)
      @mutex.synchronize { @queue.enqueue_now(tracks, playing: @playing) }
      @commands << :play_head
    end

    def enqueue_front(tracks)
      @mutex.synchronize { @queue.enqueue_front(tracks, playing: @playing) }
    end

    def enqueue_end(tracks)
      @mutex.synchronize { @queue.enqueue_end(tracks) }
    end

    def remove_at(index)
      @mutex.synchronize do
        # index 0 while playing is the current track: removing it = skip
        if index.zero? && @playing
          @commands << :skip
          nil
        else
          @queue.remove_at(index)
        end
      end
    end

    def undo = @mutex.synchronize { @queue.undo }
    def redo = @mutex.synchronize { @queue.redo }

    def toggle_play
      if @playing
        @commands << :toggle_pause
      else
        @commands << :play_head # no-op in the loop if the queue is empty
      end
    end

    def skip = @commands << :skip
    def seek(ms) = @commands << [:seek, ms]

    def toggle_skip_disliked
      @skip_disliked = !@skip_disliked
    end

    def queue_items = @mutex.synchronize { @queue.items }
    def levels = @level_tap.levels

    def state
      @mutex.synchronize do
        { track: @current, playing: @playing, paused: @paused,
          position_ms: position_ms, skip_disliked: @skip_disliked }
      end
    end

    private

    def position_ms
      return 0 unless @playing
      played = @audio.frames_played - @frames_base
      @seek_offset_ms + (played * 1000 / @audio.sample_rate)
    end

    # ---- decoder thread ----

    def run
      loop do
        cmd = begin
          @commands.pop(timeout: @playing && !@paused ? 0 : 0.05)
        rescue ThreadError
          nil
        end
        case cmd
        when :stop then break
        when :play_head then play_head
        when :skip then finish_and_advance
        when :toggle_pause then toggle_pause
        when Array then handle_seek(cmd[1]) if cmd[0] == :seek
        end
        pump if @playing && !@paused
      end
      close_handle
    end

    def pump
      if @pending
        written = @audio.write(@pending)
        consumed = written * AudioOutput::BYTES_PER_FRAME
        @pending = consumed < @pending.bytesize ? @pending.byteslice(consumed..) : nil
        sleep 0.005 if @pending # buffer full: yield briefly, stay responsive
        return
      end
      data = @handle&.read(@chunk_frames)
      if data.nil?
        finish_and_advance
      else
        @level_tap.push(data)
        @pending = data
        @bus.publish(:position, position_ms: position_ms, track_id: @current&.id)
      end
    end

    def play_head
      target = @mutex.synchronize { @queue.first }
      return if target.nil?
      close_handle
      open_and_play(target)
    end

    def open_and_play(track)
      track = next_playable(track)
      if track.nil?
        stop_playback
        return
      end
      backend = @registry.backend_for(track.physical_path)
      @handle = backend.open(track.physical_path, track.subtune_index,
                             sample_rate: @audio.sample_rate)
      @audio.paused = true
      @audio.flush
      @audio.paused = false
      @mutex.synchronize do
        @current = track
        @playing = true
        @paused = false
        @frames_base = @audio.frames_played
        @seek_offset_ms = 0
        @started_at = Time.now.utc
      end
      @level_tap.reset
      @bus.publish(:track_started, track: track)
      @bus.publish(:playback_state, playing: true, paused: false)
    rescue StandardError => e
      @library.set_errored(track.id) if track&.id
      @bus.publish(:track_error, track: track, message: e.message)
      @mutex.synchronize { @queue.advance! }
      retry_next = @mutex.synchronize { @queue.first }
      retry_next ? open_and_play(retry_next) : stop_playback
    end

    # Applies the skip-rated-1 rule, advancing past disliked tracks.
    def next_playable(track)
      while track && @skip_disliked && @library.rating_of(track.id) == 1
        track = @mutex.synchronize { @queue.advance! }
      end
      track
    end

    def finish_and_advance
      record_history
      @bus.publish(:track_ended, track: @current) if @current
      nxt = @mutex.synchronize { @queue.advance! }
      close_handle
      nxt ? open_and_play(nxt) : stop_playback
    end

    def stop_playback
      close_handle
      @audio.paused = true
      @audio.flush
      @mutex.synchronize do
        @current = nil
        @playing = false
        @paused = false
      end
      @bus.publish(:playback_state, playing: false, paused: false)
    end

    def toggle_pause
      return unless @playing
      @mutex.synchronize { @paused = !@paused }
      @audio.paused = @paused
      @bus.publish(:playback_state, playing: true, paused: @paused)
    end

    def handle_seek(ms)
      return unless @playing && @handle
      @audio.paused = true
      @audio.flush
      @pending = nil
      if @handle.seek(ms)
        @mutex.synchronize do
          @seek_offset_ms = ms
          @frames_base = @audio.frames_played
        end
      end
      @audio.paused = @paused
    end

    def record_history
      track = @current
      return unless track
      played_ms = position_ms
      threshold = if track.duration_ms&.positive?
                    track.duration_ms * @history_min_pct / 100.0
                  else
                    @history_min_unknown_ms
                  end
      return if played_ms < threshold
      @library.record_history(track_id: track.id,
                              started_at: @started_at.iso8601,
                              ended_at: Time.now.utc.iso8601)
    end

    def close_handle
      @handle&.close
      @handle = nil
      @pending = nil
    end
  end
end
```

Also add to `lib/rubyplayer/library.rb` (the engine flags decode failures):
```ruby
    def set_errored(track_id)
      @db.write { |s| s.execute("UPDATE tracks SET errored = 1 WHERE id = ?", [track_id]) }
    end
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bundle exec ruby -Itest test/playback_engine_test.rb`
Expected: `5 runs ... 0 failures, 0 errors`
These are timing-based integration tests against the null audio device; if one flakes,
raise the `wait_for` timeout rather than adding sleeps.

Run the full suite to check nothing regressed: `bundle exec rake test`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/config.rb lib/rubyplayer/level_tap.rb \
        lib/rubyplayer/playback_engine.rb lib/rubyplayer/library.rb \
        test/level_tap_test.rb test/playback_engine_test.rb
git commit -m "feat: PlaybackEngine decoder thread + LevelTap EQ analysis"
```

---

### Task 15: EventBus (thread-safe events + select()-able wakeup)

Background threads publish; the main loop `IO.select`s on `bus.reader` alongside stdin and
drains. This is the self-pipe trick: one byte written per publish wakes the UI instantly.

**Files:**
- Create: `lib/rubyplayer/event_bus.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/event_bus"`)
- Test: `test/event_bus_test.rb`

**Interfaces:**
- Produces `RubyPlayer::EventBus.new`:
  - `#publish(type, **payload)` — thread-safe, never blocks (a full pipe is fine; the byte is only a wakeup hint).
  - `#drain` ⇒ `[[type, payload], ...]` and clears the wakeup pipe.
  - `#reader` ⇒ IO for `IO.select`.
  - Duck-type note: anything with `publish(type, **payload)` satisfies consumers (ExtractorPool, PlaybackEngine) — tests already use fakes.

- [ ] **Step 1: Write the failing test**

`test/event_bus_test.rb`:
```ruby
require "test_helper"

class EventBusTest < Minitest::Test
  def test_publish_drain_roundtrip
    bus = RubyPlayer::EventBus.new
    bus.publish(:track_started, id: 7)
    bus.publish(:position, ms: 100)
    events = bus.drain
    assert_equal [[:track_started, { id: 7 }], [:position, { ms: 100 }]], events
    assert_empty bus.drain
  end

  def test_publish_wakes_select
    bus = RubyPlayer::EventBus.new
    Thread.new { sleep 0.05; bus.publish(:ping) }
    ready = IO.select([bus.reader], nil, nil, 2)
    refute_nil ready, "publish should make the reader selectable"
    bus.drain
    assert_nil IO.select([bus.reader], nil, nil, 0.05), "drain should clear the pipe"
  end

  def test_many_publishes_never_block
    bus = RubyPlayer::EventBus.new
    100_000.times { |i| bus.publish(:tick, i: i) } # far beyond pipe capacity
    assert_equal 100_000, bus.drain.size
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/event_bus_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::EventBus`

- [ ] **Step 3: Implement**

`lib/rubyplayer/event_bus.rb`:
```ruby
module RubyPlayer
  # Thread-safe event queue with a select()-able wakeup pipe (self-pipe trick).
  # Producers: scanner pool, playback engine. Consumer: the main UI loop.
  class EventBus
    attr_reader :reader

    def initialize
      @queue = Thread::Queue.new
      @reader, @writer = IO.pipe
    end

    def publish(type, **payload)
      @queue << [type, payload]
      begin
        @writer.write_nonblock("!")
      rescue IO::WaitWritable, Errno::EAGAIN
        # pipe full — a wakeup byte is already pending, which is all we need
      end
    end

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
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/event_bus"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/event_bus_test.rb`
Expected: `3 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/event_bus.rb test/event_bus_test.rb
git commit -m "feat: EventBus with self-pipe wakeup for the UI select loop"
```

---

### Task 16: Screen (double-buffered diff renderer)

Immediate-mode: each frame, views `put` styled text into the back buffer; `flush` diffs
against the front buffer and emits ANSI only for changed cells. App-agnostic — knows
nothing about panes or tracks. Colors: `nil` (terminal default), ANSI names as symbols
(`:red`, `:bright_cyan`, ...), or `"#rrggbb"` truecolor strings — this is what makes
Phase 3 RGB themes free.

Known limitation (fine for MVP): every character is assumed one column wide. Most Nerd
Font glyphs are; if a double-width glyph misrenders, pick a single-width glyph in config.

**Files:**
- Create: `lib/rubyplayer/ui/screen.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/ui/screen"`)
- Test: `test/screen_test.rb`

**Interfaces:**
- Produces:
  - `RubyPlayer::UI::Cell` — `Struct.new(:ch, :fg, :bg, :bold)` (value equality drives the diff).
  - `RubyPlayer::UI::Screen.new(out:, rows:, cols:)`
  - `#put(row, col, text, fg: nil, bg: nil, bold: false)` — clips silently at bounds.
  - `#clear_back` — call at the start of each frame (immediate mode).
  - `#flush` ⇒ the emitted String (also written to `out`); "" when nothing changed.
  - `#resize(rows, cols)` — drops the front buffer, forcing a full repaint.
  - `#rows` / `#cols`

- [ ] **Step 1: Write the failing test**

`test/screen_test.rb`:
```ruby
require "test_helper"
require "stringio"

class ScreenTest < Minitest::Test
  def make_screen(rows: 5, cols: 20)
    RubyPlayer::UI::Screen.new(out: StringIO.new, rows: rows, cols: cols)
  end

  def test_flush_paints_and_positions
    s = make_screen
    s.flush # baseline: the first flush paints the whole blank screen
    s.clear_back
    s.put(1, 2, "hello")
    out = s.flush
    assert_includes out, "hello"
    assert_includes out, "\e[2;3H" # row 1, col 2 -> ANSI is 1-based
  end

  def test_unchanged_frame_emits_nothing
    s = make_screen
    s.put(0, 0, "x")
    s.flush
    s.clear_back
    s.put(0, 0, "x")
    assert_equal "", s.flush
  end

  def test_diff_emits_only_changed_cells
    s = make_screen
    s.put(0, 0, "aaaaaaaaaa")
    s.flush
    s.clear_back
    s.put(0, 0, "aaaaaaaaab") # one changed cell
    out = s.flush
    assert_includes out, "\e[1;10H"
    refute_includes out.delete_prefix("\e[1;10H"), "a" * 3, "should not repaint unchanged run"
  end

  def test_truecolor_and_named_colors
    s = make_screen
    s.put(0, 0, "R", fg: "#ff0000")
    s.put(0, 1, "G", fg: :bright_green, bold: true)
    out = s.flush
    assert_includes out, "38;2;255;0;0"
    assert_includes out, "\e[0;1;92m" # bold + bright_green as one SGR
  end

  def test_clipping_out_of_bounds
    s = make_screen(rows: 2, cols: 5)
    s.put(0, 3, "abcdef") # clips at col 5
    s.put(9, 0, "nope")   # row out of range: ignored
    out = s.flush
    assert_includes out, "ab"
    refute_includes out, "c"
    refute_includes out, "nope"
  end

  def test_resize_forces_full_repaint
    s = make_screen
    s.put(0, 0, "hi")
    s.flush
    s.resize(5, 20)
    s.put(0, 0, "hi")
    assert_includes s.flush, "hi"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/screen_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::UI`

- [ ] **Step 3: Implement**

`lib/rubyplayer/ui/screen.rb`:
```ruby
module RubyPlayer
  module UI
    Cell = Struct.new(:ch, :fg, :bg, :bold)
    BLANK = Cell.new(" ", nil, nil, false).freeze

    class Screen
      FG_CODES = { black: 30, red: 31, green: 32, yellow: 33, blue: 34,
                   magenta: 35, cyan: 36, white: 37,
                   bright_black: 90, bright_red: 91, bright_green: 92,
                   bright_yellow: 93, bright_blue: 94, bright_magenta: 95,
                   bright_cyan: 96, bright_white: 97 }.freeze

      attr_reader :rows, :cols

      def initialize(out:, rows:, cols:)
        @out = out
        resize(rows, cols)
      end

      def resize(rows, cols)
        @rows = rows
        @cols = cols
        @front = nil # force full repaint
        @back = blank_buffer
      end

      def clear_back
        @back = blank_buffer
      end

      def put(row, col, text, fg: nil, bg: nil, bold: false)
        return if row.negative? || row >= @rows
        text.each_char.with_index do |ch, i|
          c = col + i
          next if c.negative?
          break if c >= @cols
          @back[row][c] = Cell.new(ch, fg, bg, bold)
        end
      end

      def flush
        out = +""
        last_style = :none
        @rows.times do |r|
          c = 0
          while c < @cols
            if @front && @front[r][c] == @back[r][c]
              c += 1
              next
            end
            out << "\e[#{r + 1};#{c + 1}H"
            while c < @cols && (@front.nil? || @front[r][c] != @back[r][c])
              cell = @back[r][c]
              style = [cell.fg, cell.bg, cell.bold]
              if style != last_style
                out << sgr(cell)
                last_style = style
              end
              out << cell.ch
              c += 1
            end
          end
        end
        unless out.empty?
          out << "\e[0m"
          @out.write(out)
          @out.flush if @out.respond_to?(:flush)
        end
        @front = @back.map(&:dup)
        out
      end

      private

      def blank_buffer
        Array.new(@rows) { Array.new(@cols) { BLANK.dup } }
      end

      def sgr(cell)
        codes = ["0"]
        codes << "1" if cell.bold
        codes << color_code(cell.fg, foreground: true) if cell.fg
        codes << color_code(cell.bg, foreground: false) if cell.bg
        "\e[#{codes.join(';')}m"
      end

      def color_code(color, foreground:)
        if color.is_a?(String) && color.start_with?("#")
          r = color[1, 2].to_i(16)
          g = color[3, 2].to_i(16)
          b = color[5, 2].to_i(16)
          "#{foreground ? 38 : 48};2;#{r};#{g};#{b}"
        else
          base = FG_CODES.fetch(color.to_sym, 37)
          (foreground ? base : base + 10).to_s
        end
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/ui/screen"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/screen_test.rb`
Expected: `6 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/ui/screen.rb test/screen_test.rb
git commit -m "feat: Screen - double-buffered ANSI diff renderer with truecolor"
```

---

### Task 17: LibraryPane (tree view)

Three fixed special nodes (Playback Queue, History, Favorite Tracks) followed by the
folder tree, flattened into visible rows. Pure row-model + selection logic, testable
without a terminal; `render` just paints the rows. The App (Task 20) draws pane borders
and calls `render` with the inner content rect.

**Files:**
- Create: `lib/rubyplayer/ui/library_pane.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/ui/library_pane"`)
- Test: `test/library_pane_test.rb`

**Interfaces:**
- Consumes: `Library#roots/#children_of` (Task 4), `Screen#put` (Task 16), glyph table `config["glyphs"]` (Task 2).
- Produces `RubyPlayer::UI::LibraryPane.new(library:, glyphs:)`:
  - `Row = Struct.new(:kind, :folder, :depth, keyword_init: true)` — `kind` ∈ `:queue, :history, :favorites, :folder`; `folder` is the folder row Hash for `:folder` kind.
  - `#rebuild!` — re-queries the library (call after scan events).
  - `#rows` ⇒ [Row]; `#selected` ⇒ Row; `#selection` ⇒ Integer.
  - `#handle_action(action)` ⇒ true if consumed: `:nav_up :nav_down :expand :collapse :select_queue`. Expand/collapse only apply to `:folder` rows; selection is clamped and rebuilt across expand/collapse.
  - `#render(screen, x:, y:, w:, h:, active:)` — paints rows with scroll-follow-selection; selected row gets a background highlight (`:blue` bg when `active`, `:bright_black` otherwise); folder rows show `<icon> <name>` with a dimmed ` (count)` suffix.

- [ ] **Step 1: Write the failing test**

`test/library_pane_test.rb`:
```ruby
require "test_helper"
require "tmpdir"
require "stringio"

class LibraryPaneTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @root = @lib.upsert_folder(parent_id: nil, name: "Music", path: "/m", kind: "dir")
    @sega = @lib.upsert_folder(parent_id: @root, name: "Sega", path: "/m/sega", kind: "dir")
    @empty = @lib.upsert_folder(parent_id: nil, name: "Empty", path: "/e", kind: "dir")
    @lib.upsert_track(folder_id: @sega, physical_path: "/m/sega/a.vgm",
                      backend: "gme", format: "vgm", title: "A")
    @lib.recompute_counts!
    @pane = RubyPlayer::UI::LibraryPane.new(library: @lib,
                                            glyphs: RubyPlayer::DEFAULTS["glyphs"])
    @pane.rebuild!
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  def kinds = @pane.rows.map(&:kind)

  def test_specials_then_visible_roots_only
    assert_equal %i[queue history favorites folder], kinds
    assert_equal "Music", @pane.rows[3].folder["name"] # Empty (0 tracks) hidden
  end

  def test_expand_and_collapse
    3.times { @pane.handle_action(:nav_down) } # select Music
    assert_equal :folder, @pane.selected.kind
    @pane.handle_action(:expand)
    assert_equal %w[Music Sega], @pane.rows.select { |r| r.kind == :folder }.map { |r| r.folder["name"] }
    assert_equal 1, @pane.rows.last.depth
    @pane.handle_action(:collapse)
    assert_equal 4, @pane.rows.size
  end

  def test_nav_clamps
    @pane.handle_action(:nav_up)
    assert_equal 0, @pane.selection
    10.times { @pane.handle_action(:nav_down) }
    assert_equal @pane.rows.size - 1, @pane.selection
  end

  def test_select_queue_jumps_home
    3.times { @pane.handle_action(:nav_down) }
    @pane.handle_action(:select_queue)
    assert_equal :queue, @pane.selected.kind
  end

  def test_render_shows_specials_folder_and_count
    screen = RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 10, cols: 40)
    @pane.render(screen, x: 0, y: 0, w: 40, h: 10, active: true)
    out = screen.flush
    assert_includes out, "Playback Queue"
    assert_includes out, "Music"
    assert_includes out, "(1)"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/library_pane_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::UI::LibraryPane`

- [ ] **Step 3: Implement**

`lib/rubyplayer/ui/library_pane.rb`:
```ruby
module RubyPlayer
  module UI
    class LibraryPane
      Row = Struct.new(:kind, :folder, :depth, keyword_init: true)

      SPECIALS = [
        [:queue, "Playback Queue"],
        [:history, "History"],
        [:favorites, "Favorite Tracks"],
      ].freeze

      attr_reader :selection

      def initialize(library:, glyphs:)
        @library = library
        @glyphs = glyphs
        @expanded = {}
        @selection = 0
        @scroll = 0
        @rows = []
      end

      def rebuild!
        @rows = SPECIALS.map { |kind, _| Row.new(kind: kind, depth: 0) }
        @library.roots.each { |f| append_folder(f, 0) }
        @selection = @selection.clamp(0, [@rows.size - 1, 0].max)
      end

      def rows = @rows
      def selected = @rows[@selection]

      def handle_action(action)
        case action
        when :nav_up then @selection = (@selection - 1).clamp(0, @rows.size - 1)
        when :nav_down then @selection = (@selection + 1).clamp(0, @rows.size - 1)
        when :expand then toggle_expand(true)
        when :collapse then toggle_expand(false)
        when :select_queue then @selection = 0
        else return false
        end
        true
      end

      def render(screen, x:, y:, w:, h:, active:)
        follow_selection(h)
        h.times do |i|
          row = @rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? :blue : :bright_black) : nil
          fg = selected ? :bright_white : nil
          screen.put(y + i, x, " " * w, bg: bg) if selected
          label, suffix = label_for(row)
          indent = "  " * row.depth
          screen.put(y + i, x, "#{indent}#{label}"[0, w], fg: fg, bg: bg, bold: selected)
          unless suffix.empty?
            col = x + indent.size + label.size + 1
            screen.put(y + i, col, suffix[0, [w - (col - x), 0].max],
                       fg: selected ? fg : :bright_black, bg: bg)
          end
        end
      end

      private

      def append_folder(folder, depth)
        @rows << Row.new(kind: :folder, folder: folder, depth: depth)
        return unless @expanded[folder["id"]]
        @library.children_of(folder["id"]).each { |c| append_folder(c, depth + 1) }
      end

      def toggle_expand(open)
        row = selected
        return unless row&.kind == :folder
        @expanded[row.folder["id"]] = open
        rebuild!
      end

      def follow_selection(height)
        @scroll = @selection if @selection < @scroll
        @scroll = @selection - height + 1 if @selection >= @scroll + height
        @scroll = @scroll.clamp(0, [@rows.size - height, 0].max)
      end

      def label_for(row)
        case row.kind
        when :queue then ["#{@glyphs['play']} Playback Queue", ""]
        when :history then ["#{@glyphs['playlist']} History", ""]
        when :favorites then ["#{@glyphs['star']} Favorite Tracks", ""]
        when :folder
          f = row.folder
          icon = @glyphs[f["kind"]] || @glyphs["dir"]
          ["#{icon} #{f['name']}", "(#{f['track_count']})"]
        end
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/ui/library_pane"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/library_pane_test.rb`
Expected: `5 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/ui/library_pane.rb test/library_pane_test.rb
git commit -m "feat: LibraryPane tree view with specials, expand/collapse, scroll"
```

---

### Task 18: TracksPane (track list: queue/history/favorites/folder views)

Content follows the LibraryPane selection. Sorting (`T`/`N`/`A`), album grouping (`G`),
and config-driven format strings (hot-reloaded via `update_config`). Row model is pure
data; render paints it.

**Files:**
- Create: `lib/rubyplayer/ui/tracks_pane.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/ui/tracks_pane"`)
- Test: `test/tracks_pane_test.rb`

**Interfaces:**
- Consumes: `Library#tracks_under/#favorites/#history` (Task 4), `Template` (Task 12), `LibraryPane::Row` (Task 17), engine's `#queue_items` via a callable to avoid a hard dependency.
- Produces `RubyPlayer::UI::TracksPane.new(library:, config:, queue_source:)` — `queue_source` is a callable returning the queue snapshot (App passes `-> { engine.queue_items }`).
  - `#show(library_row)` — switch content to the given LibraryPane Row; resets selection.
  - `#reload!` — re-query the current source (after `:queue_changed`/scan events).
  - `#update_config(config)` — rebuild Templates (config hot-reload).
  - `#handle_action(action)` ⇒ bool: `:nav_up :nav_down :toggle_group :sort_title :sort_number :sort_artist`.
  - `#display_rows` ⇒ `[{type: :header, text:} | {type: :track, text:, track:}]` — grouped mode inserts album header rows and uses the grouped template with `album_artist` = the group's dominant artist; flat mode uses the ungrouped template.
  - `#selected_track` ⇒ Track or nil (headers are skipped by selection); `#selection` ⇒ Integer (index into display_rows).
  - `#render(screen, x:, y:, w:, h:, active:)` — same highlight rules as LibraryPane; headers bold cyan.

- [ ] **Step 1: Write the failing test**

`test/tracks_pane_test.rb`:
```ruby
require "test_helper"
require "tmpdir"

class TracksPaneTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @db = RubyPlayer::Database.new(path: File.join(@tmp, "library.sqlite3"))
    @lib = RubyPlayer::Library.new(@db)
    @folder = @lib.upsert_folder(parent_id: nil, name: "m", path: "/m", kind: "dir")
    add("c.vgm", title: "Charlie", album: "Zebra", artist: "X", number: 1)
    add("a.vgm", title: "Alpha",   album: "Apple", artist: "X", number: 2)
    add("b.vgm", title: "Bravo",   album: "Apple", artist: "Y", number: 1)
    @lib.recompute_counts!
    @config = RubyPlayer::ConfigStore.new(path: "/nonexistent.toml")
    @queue = []
    @pane = RubyPlayer::UI::TracksPane.new(library: @lib, config: @config,
                                           queue_source: -> { @queue })
    @folder_row = RubyPlayer::UI::LibraryPane::Row.new(
      kind: :folder, folder: { "id" => @folder }, depth: 0
    )
  end

  def teardown
    @db.close
    FileUtils.remove_entry(@tmp)
  end

  def add(file, title:, album:, artist:, number:)
    @lib.upsert_track(folder_id: @folder, physical_path: "/m/#{file}",
                      backend: "gme", format: "vgm", title: title, album: album,
                      artist: artist, track_number: number, duration_ms: 60_000)
  end

  def titles = @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].title }

  def test_folder_view_lists_tracks
    @pane.show(@folder_row)
    assert_equal 3, titles.size
  end

  def test_sorting
    @pane.show(@folder_row)
    @pane.handle_action(:sort_title)
    assert_equal %w[Alpha Bravo Charlie], titles
    @pane.handle_action(:sort_artist)
    assert_equal %w[X X Y].sort, @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].artist }.sort
    @pane.handle_action(:sort_number)
    assert_equal [1, 1, 2].sort, @pane.display_rows.select { |r| r[:type] == :track }.map { |r| r[:track].track_number }.sort
  end

  def test_grouping_inserts_album_headers_sorted_by_album
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    rows = @pane.display_rows
    headers = rows.select { |r| r[:type] == :header }.map { |r| r[:text] }
    assert_equal %w[Apple Zebra], headers
    assert_equal :header, rows.first[:type]
  end

  def test_grouped_template_hides_artist_matching_album_artist
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    apple_rows = @pane.display_rows.select { |r| r[:type] == :track && r[:track].album == "Apple" }
    x_row = apple_rows.find { |r| r[:track].artist == "X" } # X is Apple's dominant artist
    y_row = apple_rows.find { |r| r[:track].artist == "Y" }
    refute_includes x_row[:text], "X"
    assert_includes y_row[:text], "Y"
  end

  def test_selection_skips_headers
    @pane.show(@folder_row)
    @pane.handle_action(:toggle_group)
    assert_equal :track, @pane.display_rows[@pane.selection][:type]
    refute_nil @pane.selected_track
  end

  def test_queue_view_uses_queue_source
    @queue = [@lib.find_track(@lib.upsert_track(
      folder_id: @folder, physical_path: "/m/q.vgm", backend: "gme",
      format: "vgm", title: "Queued"
    ))]
    @pane.show(RubyPlayer::UI::LibraryPane::Row.new(kind: :queue, depth: 0))
    assert_equal %w[Queued], titles
  end

  def test_config_hot_reload_changes_format
    @pane.show(@folder_row)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "c.toml")
      File.write(path, "[ui]\nformat_string_ungrouped = \"<<{title}>>\"\n")
      @pane.update_config(RubyPlayer::ConfigStore.new(path: path))
      assert_includes @pane.display_rows.first[:text], "<<"
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/tracks_pane_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::UI::TracksPane`

- [ ] **Step 3: Implement**

`lib/rubyplayer/ui/tracks_pane.rb`:
```ruby
module RubyPlayer
  module UI
    class TracksPane
      attr_reader :selection

      def initialize(library:, config:, queue_source:)
        @library = library
        @queue_source = queue_source
        @mode = nil
        @tracks = []
        @selection = 0
        @scroll = 0
        @group_by_album = false
        @sort = nil
        update_config(config)
      end

      def update_config(config)
        star = config["glyphs", "star"]
        @grouped_template = Template.new(config["ui", "format_string_grouped"], star_glyph: star)
        @flat_template = Template.new(config["ui", "format_string_ungrouped"], star_glyph: star)
        @history_limit = config["library", "history_limit"]
      end

      def show(library_row)
        @mode = library_row.kind == :folder ? [:folder, library_row.folder["id"]] : library_row.kind
        @selection = 0
        @scroll = 0
        reload!
      end

      def reload!
        @tracks =
          case @mode
          when :queue then @queue_source.call
          when :history then @library.history(limit: @history_limit).map { |h| h[:track] }
          when :favorites then @library.favorites
          when Array then @library.tracks_under(@mode[1])
          else []
          end
        apply_sort
        clamp_selection
      end

      def handle_action(action)
        case action
        when :nav_up then move_selection(-1)
        when :nav_down then move_selection(1)
        when :toggle_group then @group_by_album = !@group_by_album
        when :sort_title then @sort = :title
        when :sort_number then @sort = :number
        when :sort_artist then @sort = :artist
        else return false
        end
        apply_sort if %i[sort_title sort_number sort_artist toggle_group].include?(action)
        clamp_selection
        true
      end

      def display_rows
        return flat_rows unless @group_by_album
        grouped_rows
      end

      def selected_track
        row = display_rows[@selection]
        row && row[:type] == :track ? row[:track] : nil
      end

      def render(screen, x:, y:, w:, h:, active:)
        rows = display_rows
        follow_selection(h, rows.size)
        h.times do |i|
          row = rows[@scroll + i] or break
          selected = (@scroll + i) == @selection
          bg = selected ? (active ? :blue : :bright_black) : nil
          screen.put(y + i, x, " " * w, bg: bg) if selected
          if row[:type] == :header
            screen.put(y + i, x, row[:text][0, w], fg: :cyan, bg: bg, bold: true)
          else
            screen.put(y + i, x, row[:text][0, w],
                       fg: selected ? :bright_white : nil, bg: bg, bold: selected)
          end
        end
      end

      private

      def flat_rows
        @tracks.map { |t| { type: :track, text: @flat_template.render(t), track: t } }
      end

      def grouped_rows
        groups = @tracks.group_by { |t| t.album.to_s }.sort_by { |album, _| album }
        groups.flat_map do |album, tracks|
          album_artist = tracks.map(&:artist).tally.max_by { |_, n| n }&.first
          [{ type: :header, text: album }] + tracks.map do |t|
            { type: :track, text: @grouped_template.render(t, album_artist: album_artist),
              track: t }
          end
        end
      end

      def apply_sort
        case @sort
        when :title then @tracks.sort_by! { |t| t.title.to_s.downcase }
        when :number then @tracks.sort_by! { |t| [t.album.to_s, t.track_number || 0] }
        when :artist then @tracks.sort_by! { |t| [t.artist.to_s.downcase, t.title.to_s.downcase] }
        end
      end

      def move_selection(delta)
        rows = display_rows
        i = @selection
        loop do
          i += delta
          return unless i.between?(0, rows.size - 1)
          break if rows[i][:type] == :track
        end
        @selection = i
      end

      def clamp_selection
        rows = display_rows
        @selection = @selection.clamp(0, [rows.size - 1, 0].max)
        # never rest on a header
        if rows[@selection] && rows[@selection][:type] == :header
          @selection += 1 if @selection + 1 < rows.size
        end
      end

      def follow_selection(height, total)
        @scroll = @selection if @selection < @scroll
        @scroll = @selection - height + 1 if @selection >= @scroll + height
        @scroll = @scroll.clamp(0, [total - height, 0].max)
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/ui/tracks_pane"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/tracks_pane_test.rb`
Expected: `8 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/ui/tracks_pane.rb test/tracks_pane_test.rb
git commit -m "feat: TracksPane with sorting, album grouping, hot-reloaded templates"
```

---

### Task 19: Bottom lines (PlaybackLine, StatusLine, HotkeyLine)

Three one-line renderers. Pure formatting over injected state — no service dependencies.

**Files:**
- Create: `lib/rubyplayer/ui/bottom_lines.rb`
- Modify: `lib/rubyplayer.rb` (add `require_relative "rubyplayer/ui/bottom_lines"`)
- Test: `test/bottom_lines_test.rb`

**Interfaces:**
- Consumes: `Screen#put` (Task 16), `Keymap#bindings_for` (Task 13), glyphs (Task 2).
- Produces (all in `RubyPlayer::UI`):
  - `PlaybackLine.new(glyphs:)` — `#render(screen, row:, w:, state:, levels:)` where `state` is `PlaybackEngine#state` and `levels` is the EQ array. Shows play/pause glyph, `Title — Artist`, `M:SS/M:SS`, plus right-aligned EQ bars built from `glyphs["eq_chars"]`. Empty state renders `"stopped"` dimmed, no bars.
  - `StatusLine.new(seconds: 5, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })` — `#set_message(text)`, `#render(screen, row:, w:, default:)`. Shows the message until `seconds` elapse (per the injected clock), then the `default` string.
  - `HotkeyLine.new(keymap:)` — `#render(screen, row:, w:, pane:)`. Renders `key:label` pairs from `Keymap#bindings_for(pane)`, truncated to width.

- [ ] **Step 1: Write the failing test**

`test/bottom_lines_test.rb`:
```ruby
require "test_helper"
require "stringio"

class BottomLinesTest < Minitest::Test
  def screen = @screen ||= RubyPlayer::UI::Screen.new(out: StringIO.new, rows: 3, cols: 60)
  def glyphs = RubyPlayer::DEFAULTS["glyphs"]

  def track = RubyPlayer::Track.new(title: "Flash Man", artist: "Capcom", duration_ms: 120_000)

  def test_playback_line_playing
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    state = { track: track, playing: true, paused: false, position_ms: 65_000 }
    line.render(screen, row: 0, w: 60, state: state, levels: [0.0, 0.5, 1.0])
    out = screen.flush
    assert_includes out, "Flash Man"
    assert_includes out, "1:05/2:00"
    assert_includes out, glyphs["eq_chars"][-1] # full-level bar char present
  end

  def test_playback_line_stopped
    line = RubyPlayer::UI::PlaybackLine.new(glyphs: glyphs)
    line.render(screen, row: 0, w: 60,
                state: { track: nil, playing: false, paused: false, position_ms: 0 },
                levels: [])
    assert_includes screen.flush, "stopped"
  end

  def test_status_line_message_expires
    now = [100.0]
    line = RubyPlayer::UI::StatusLine.new(seconds: 5, clock: -> { now[0] })
    line.set_message("45 tracks enqueued")
    line.render(screen, row: 1, w: 60, default: "3 folders")
    assert_includes screen.flush, "45 tracks enqueued"
    now[0] = 106.0
    screen.clear_back
    line.render(screen, row: 1, w: 60, default: "3 folders")
    out = screen.flush
    assert_includes out, "3 folders"
    refute_includes out, "enqueued"
  end

  def test_hotkey_line_lists_pane_bindings
    line = RubyPlayer::UI::HotkeyLine.new(keymap: RubyPlayer::Keymap.new)
    line.render(screen, row: 2, w: 60, pane: :tracks)
    out = screen.flush
    assert_includes out, "G:group"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec ruby -Itest test/bottom_lines_test.rb`
Expected: FAIL — `uninitialized constant RubyPlayer::UI::PlaybackLine`

- [ ] **Step 3: Implement**

`lib/rubyplayer/ui/bottom_lines.rb`:
```ruby
module RubyPlayer
  module UI
    class PlaybackLine
      def initialize(glyphs:)
        @glyphs = glyphs
      end

      def render(screen, row:, w:, state:, levels:)
        if state[:track].nil?
          screen.put(row, 0, "#{@glyphs['pause']} stopped", fg: :bright_black)
          return
        end
        t = state[:track]
        icon = state[:paused] ? @glyphs["pause"] : @glyphs["play"]
        time = "#{fmt(state[:position_ms])}/#{fmt(t.duration_ms)}"
        text = "#{icon} #{t.title}#{t.artist ? " — #{t.artist}" : ''}  #{time}"
        bars = eq_bars(levels)
        screen.put(row, 0, text[0, w - bars.size - 1], fg: :bright_white, bold: true)
        screen.put(row, w - bars.size, bars, fg: :green)
      end

      private

      def eq_bars(levels)
        chars = @glyphs["eq_chars"]
        levels.map { |l| chars[(l * (chars.size - 1)).round] }.join
      end

      def fmt(ms)
        return "?:??" unless ms
        total = ms / 1000
        format("%d:%02d", total / 60, total % 60)
      end
    end

    class StatusLine
      def initialize(seconds: 5, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @seconds = seconds
        @clock = clock
        @message = nil
        @expires_at = 0.0
      end

      def set_message(text)
        @message = text
        @expires_at = @clock.call + @seconds
      end

      def render(screen, row:, w:, default:)
        text = @message && @clock.call < @expires_at ? @message : default
        screen.put(row, 0, text.to_s[0, w], fg: :yellow)
      end
    end

    class HotkeyLine
      LABELS = {
        cycle_pane: "panes", toggle_play: "play/pause", play_now: "play now",
        enqueue_front: "queue next", enqueue_end: "queue last", select_queue: "queue",
        undo: "undo", redo: "redo", toggle_skip_disliked: "skip 1-star", add_path: "add",
        quit: "quit", nav_up: nil, nav_down: nil, collapse: nil, expand: nil,
        toggle_group: "group", sort_title: "title", sort_number: "number",
        sort_artist: "artist",
      }.freeze

      def initialize(keymap:)
        @keymap = keymap
      end

      def render(screen, row:, w:, pane:)
        pairs = @keymap.bindings_for(pane).filter_map do |key, action|
          next if action.to_s.start_with?("rate_")
          label = LABELS.fetch(action, action.to_s)
          label ? "#{key}:#{label}" : nil
        end
        screen.put(row, 0, pairs.join("  ")[0, w], fg: :bright_black)
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/ui/bottom_lines"`

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec ruby -Itest test/bottom_lines_test.rb`
Expected: `4 runs ... 0 failures, 0 errors`

- [ ] **Step 5: Commit**

```bash
git add lib/rubyplayer.rb lib/rubyplayer/ui/bottom_lines.rb test/bottom_lines_test.rb
git commit -m "feat: playback/status/hotkey bottom lines"
```

---

### Task 20: App (main loop, key decoding, wiring) + bin/rubyplayer

Everything meets here: terminal setup, the select loop with self-pipe wakeup, key decoding,
action dispatch, layout with pane borders, the add-path input mode, config hot-reload, and
startup scanning of known roots.

**Files:**
- Create: `lib/rubyplayer/ui/key_decoder.rb`, `lib/rubyplayer/ui/app.rb`, `bin/rubyplayer` (chmod +x)
- Modify: `lib/rubyplayer/library.rb` (add `root_paths`), `lib/rubyplayer/config.rb` (add `RubyPlayer.logger`), `lib/rubyplayer.rb` (add `require_relative "rubyplayer/ui/key_decoder"`; App itself is NOT required from rubyplayer.rb — it pulls in audio, so `bin/rubyplayer` and tests require it explicitly)
- Test: `test/key_decoder_test.rb`, `test/app_test.rb`

**Interfaces:**
- Consumes: everything above.
- Produces:
  - `RubyPlayer::UI::KeyDecoder.decode(bytes)` ⇒ array of normalized key-name strings (Keymap's vocabulary, Task 13). Strips bracketed-paste markers, passing pasted characters through.
  - `RubyPlayer::UI::App.new(argv: [], config_path: nil, data_path: nil, null_audio: false, io_out: $stdout)` — keyword args are test seams; production uses defaults.
  - `#run` — full lifecycle. `#handle_key(key)`, `#handle_events`, `#scan_paths(paths, wait: false)`, `#shutdown`, `#quit?`, and readers `#engine #library_pane #tracks_pane #active_pane #input_buffer` are public for tests.
  - `Library#root_paths` ⇒ all top-level folder paths (`parent_id IS NULL`), regardless of visibility — the roots rescanned on startup.
  - `bin/rubyplayer [PATH ...]` — optional paths are added to the library on startup.

- [ ] **Step 1: Write the failing KeyDecoder test**

`test/key_decoder_test.rb` — NOTE: control keys are written as `\u` escapes in Ruby
source (`"\u007F"` = DEL/backspace, `"\u0012"` = Ctrl-R, `"\u0003"` = Ctrl-C). Keep them
as escapes; do not paste literal control bytes into the file.
```ruby
require "test_helper"
require "rubyplayer/ui/key_decoder"

class KeyDecoderTest < Minitest::Test
  def decode(s) = RubyPlayer::UI::KeyDecoder.decode(s)

  def test_printable_chars_pass_through_case_sensitive
    assert_equal ["a"], decode("a")
    assert_equal ["N"], decode("N")
    assert_equal %w[a b], decode("ab")
  end

  def test_special_keys
    assert_equal ["up"], decode("\e[A")
    assert_equal ["down"], decode("\e[B")
    assert_equal ["right"], decode("\e[C")
    assert_equal ["left"], decode("\e[D")
    assert_equal ["enter"], decode("\r")
    assert_equal ["tab"], decode("\t")
    assert_equal ["space"], decode(" ")
    assert_equal ["escape"], decode("\e")
    assert_equal ["backspace"], decode("\u007F")
  end

  def test_ctrl_chords
    assert_equal ["ctrl_r"], decode("\u0012")
    assert_equal ["ctrl_c"], decode("\u0003")
  end

  def test_bracketed_paste_markers_stripped
    assert_equal %w[/ t m p], decode("\e[200~/tmp\e[201~")
  end
end
```

Run: `bundle exec ruby -Itest test/key_decoder_test.rb`
Expected: FAIL — `cannot load such file -- rubyplayer/ui/key_decoder`

- [ ] **Step 2: Implement KeyDecoder**

`lib/rubyplayer/ui/key_decoder.rb`:
```ruby
module RubyPlayer
  module UI
    # Normalizes raw terminal bytes into Keymap key-name strings.
    module KeyDecoder
      ESC_SEQS = { "[A" => "up", "[B" => "down", "[C" => "right", "[D" => "left" }.freeze

      def self.decode(bytes)
        keys = []
        i = 0
        while i < bytes.length
          ch = bytes[i]
          if ch == "\e"
            if bytes[i + 1] == "["
              seq_end = i + 2
              seq_end += 1 while seq_end < bytes.length && !bytes[seq_end].match?(/[a-zA-Z~]/)
              seq = bytes[(i + 1)..seq_end]
              keys << ESC_SEQS[seq] if ESC_SEQS[seq] # paste markers & unknown seqs: dropped
              i = seq_end + 1
            else
              keys << "escape"
              i += 1
            end
          elsif ch == "\r" || ch == "\n" then keys << "enter"; i += 1
          elsif ch == "\t" then keys << "tab"; i += 1
          elsif ch == " " then keys << "space"; i += 1
          elsif ch == "\u007F" then keys << "backspace"; i += 1
          elsif ch.ord < 32 then keys << "ctrl_#{(ch.ord + 96).chr}"; i += 1
          else keys << ch; i += 1
          end
        end
        keys
      end
    end
  end
end
```

Add to `lib/rubyplayer.rb`: `require_relative "rubyplayer/ui/key_decoder"`

Run: `bundle exec ruby -Itest test/key_decoder_test.rb`
Expected: `4 runs ... 0 failures, 0 errors`

- [ ] **Step 3: Write the failing App test**

`test/app_test.rb`:
```ruby
require "test_helper"
require "tmpdir"
require "fileutils"
require "stringio"
require "rubyplayer/ui/app"

class AppTest < Minitest::Test
  def setup
    @tmp = Dir.mktmpdir
    @music = File.join(@tmp, "music")
    FileUtils.mkdir_p(@music)
    FileUtils.cp(File.join(FIXTURES, "space-debris.mod"), @music)
    FileUtils.cp(File.join(FIXTURES, "shantae.gbs"), @music)
    @app = RubyPlayer::UI::App.new(
      config_path: File.join(@tmp, "config.toml"),
      data_path: File.join(@tmp, "library.sqlite3"),
      null_audio: true, io_out: StringIO.new
    )
    @app.scan_paths([@music], wait: true)
  end

  def teardown
    @app.shutdown
    FileUtils.remove_entry(@tmp)
  end

  def test_scan_populates_library_and_panes
    rows = @app.library_pane.rows
    assert_equal :folder, rows[3].kind
    assert_operator rows[3].folder["track_count"], :>=, 2
  end

  def test_navigate_and_enqueue_folder
    3.times { @app.handle_key("down") } # select the music folder
    @app.handle_key("n")                # enqueue_end the whole folder
    assert_operator @app.engine.queue_items.size, :>=, 2
  end

  def test_tab_cycles_active_pane
    assert_equal :library, @app.active_pane
    @app.handle_key("tab")
    assert_equal :tracks, @app.active_pane
  end

  def test_undo_restores_queue_and_selects_queue
    3.times { @app.handle_key("down") }
    @app.handle_key("n")
    before = @app.engine.queue_items.size
    @app.handle_key("u")
    assert_equal 0, @app.engine.queue_items.size
    assert_equal :queue, @app.library_pane.selected.kind
    @app.handle_key("ctrl_r")
    assert_equal before, @app.engine.queue_items.size
  end

  def test_add_path_mode_collects_input
    @app.handle_key("a")
    "xy".each_char { |c| @app.handle_key(c) }
    assert_equal "xy", @app.input_buffer
    @app.handle_key("escape")
    assert_nil @app.input_buffer
  end

  def test_quit_key
    @app.handle_key("ctrl_c")
    assert @app.quit?
  end
end
```

Run: `bundle exec ruby -Itest test/app_test.rb`
Expected: FAIL — `cannot load such file -- rubyplayer/ui/app`

- [ ] **Step 4: Implement Library#root_paths and App**

Add to `lib/rubyplayer/library.rb`:
```ruby
    # All top-level roots (regardless of visibility) — rescanned on startup.
    def root_paths
      @db.read do |s|
        s.execute("SELECT path FROM folders WHERE parent_id IS NULL").map { |r| r["path"] }
      end
    end
```

`lib/rubyplayer/ui/app.rb`:
```ruby
require "io/console"
require "tty-screen"
require_relative "../../rubyplayer"
require_relative "../audio_output"
require_relative "../playback_engine"

module RubyPlayer
  module UI
    class App
      RATE_ACTIONS = { rate_0: nil, rate_1: 1, rate_2: 2, rate_3: 3,
                       rate_4: 4, rate_5: 5, rate_6: 6 }.freeze

      attr_reader :engine, :library_pane, :tracks_pane, :active_pane, :input_buffer

      def initialize(argv: [], config_path: nil, data_path: nil, null_audio: false,
                     io_out: $stdout)
        @argv = argv
        @io_out = io_out
        @config = ConfigStore.new(path: config_path || RubyPlayer.config_path)
        @db = Database.new(path: data_path || File.join(RubyPlayer.data_dir, "library.sqlite3"),
                           backup_retention: @config["library", "backup_retention"])
        @library = Library.new(@db)
        @registry = Backends::Registry.new(@config["backends"])
        @bus = EventBus.new
        @audio = AudioOutput.new(sample_rate: @config["audio", "sample_rate"],
                                 ring_buffer_ms: @config["audio", "ring_buffer_ms"],
                                 null_backend: null_audio)
        @engine = PlaybackEngine.new(
          queue: PlayQueue.new(undo_depth: @config["library", "undo_depth"]),
          registry: @registry, audio: @audio, library: @library,
          event_bus: @bus, config: @config
        )
        @scanner = Scanner.new(library: @library, registry: @registry)
        @pool = ExtractorPool.new(library: @library, registry: @registry,
                                  thread_count: @config["scanner", "thread_count"],
                                  event_bus: @bus)
        @keymap = Keymap.new(@config["keymap"])
        glyphs = @config["glyphs"]
        @library_pane = LibraryPane.new(library: @library, glyphs: glyphs)
        @tracks_pane = TracksPane.new(library: @library, config: @config,
                                      queue_source: -> { @engine.queue_items })
        @playback_line = PlaybackLine.new(glyphs: glyphs)
        @status_line = StatusLine.new(seconds: @config["ui", "status_message_seconds"])
        @hotkey_line = HotkeyLine.new(keymap: @keymap)
        rows, cols = TTY::Screen.size
        @screen = Screen.new(out: io_out, rows: rows, cols: cols)
        @active_pane = :library
        @input_buffer = nil
        @quit = false
        @resized = false
        @engine.start
        @library_pane.rebuild!
      end

      def quit? = @quit

      # Scans paths on a background thread; wait: true blocks (tests, startup
      # ordering). Progress arrives via the EventBus either way.
      def scan_paths(paths, wait: false)
        thread = Thread.new do
          paths.each { |p| @pool.process(@scanner.reconcile(p)) }
        end
        if wait
          thread.join
          refresh_panes
        end
        thread
      end

      def run
        setup_terminal
        trap("SIGWINCH") { @resized = true }
        scan_paths(@library.root_paths + @argv)
        frame_interval = 1.0 / @config["ui", "frame_fps"]
        until @quit
          ready = IO.select([$stdin, @bus.reader], nil, nil, frame_interval)
          read_input if ready&.first&.include?($stdin)
          handle_events
          handle_resize if @resized
          reload_config_if_changed
          render
        end
      ensure
        restore_terminal
        shutdown
      end

      def shutdown
        @engine.shutdown
        @audio.close
        @db.close
      end

      # ---- input ----

      def read_input
        bytes = $stdin.read_nonblock(1024)
        KeyDecoder.decode(bytes).each { |key| handle_key(key) }
      rescue IO::WaitReadable, EOFError
        nil
      end

      def handle_key(key)
        return handle_input_mode_key(key) if @input_buffer
        action = @keymap.action_for(key, pane: @active_pane)
        dispatch(action) if action
      end

      def handle_input_mode_key(key)
        case key
        when "enter"
          path = @input_buffer.strip
          @input_buffer = nil
          unless path.empty?
            @status_line.set_message("Scanning #{path}...")
            scan_paths([File.expand_path(path)])
          end
        when "escape" then @input_buffer = nil
        when "backspace" then @input_buffer = @input_buffer[0..-2]
        when "space" then @input_buffer += " "
        else @input_buffer += key if key.length == 1
        end
      end

      def dispatch(action)
        case action
        when :quit then @quit = true
        when :cycle_pane
          @active_pane = @active_pane == :library ? :tracks : :library
        when :toggle_play then @engine.toggle_play
        when :play_now then enqueue(:now)
        when :enqueue_front then enqueue(:front)
        when :enqueue_end then enqueue(:end)
        when :select_queue then select_queue
        when :undo
          @status_line.set_message("Queue restored (u:undo ctrl_r:redo)") if @engine.undo
          select_queue
        when :redo
          @engine.redo
          select_queue
        when :toggle_skip_disliked
          on = @engine.toggle_skip_disliked
          @status_line.set_message("Skip disliked tracks: #{on ? 'ON' : 'OFF'}")
        when :add_path then @input_buffer = ""
        when *RATE_ACTIONS.keys then rate_current(RATE_ACTIONS[action])
        else route_to_pane(action)
        end
      end

      def route_to_pane(action)
        if @active_pane == :library
          before = @library_pane.selected
          @library_pane.handle_action(action)
          @tracks_pane.show(@library_pane.selected) if @library_pane.selected != before
        else
          @tracks_pane.handle_action(action)
        end
      end

      def enqueue(where)
        tracks = selected_tracks
        return if tracks.empty?
        case where
        when :now then @engine.enqueue_now(tracks)
        when :front then @engine.enqueue_front(tracks)
        when :end then @engine.enqueue_end(tracks)
        end
        @status_line.set_message("#{tracks.size} track#{'s' if tracks.size != 1} enqueued (u:undo)")
      end

      def selected_tracks
        if @active_pane == :tracks
          Array(@tracks_pane.selected_track)
        else
          row = @library_pane.selected
          case row&.kind
          when :folder then @library.tracks_under(row.folder["id"])
          when :favorites then @library.favorites
          else []
          end
        end
      end

      def rate_current(rating)
        track = @engine.state[:track]
        return unless track
        @library.set_rating(track.id, rating)
        @status_line.set_message(rating ? "Rated #{rating}/6" : "Rating cleared")
        @tracks_pane.reload!
      end

      def select_queue
        @library_pane.handle_action(:select_queue)
        @tracks_pane.show(@library_pane.selected)
        @active_pane = :library
      end

      # ---- events / config ----

      def handle_events
        refresh = false
        @bus.drain.each do |type, payload|
          case type
          when :queue_changed, :track_started, :track_ended then refresh = true
          when :scan_complete
            @status_line.set_message(
              "Scan complete: #{payload[:processed]} files, #{payload[:errored]} errors"
            )
            refresh = true
          when :track_error
            @status_line.set_message("Error playing #{payload[:track]&.title}: skipped")
          end
        end
        refresh_panes if refresh
      end

      def refresh_panes
        @library_pane.rebuild!
        @tracks_pane.show(@library_pane.selected)
      end

      def reload_config_if_changed
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        @last_config_check ||= now
        return if now - @last_config_check < 1.0
        @last_config_check = now
        return unless @config.reload_if_changed
        @keymap = Keymap.new(@config["keymap"])
        @hotkey_line = HotkeyLine.new(keymap: @keymap)
        @tracks_pane.update_config(@config)
        @status_line.set_message("Config reloaded")
      end

      # ---- rendering ----

      def render
        @screen.clear_back
        rows = @screen.rows
        cols = @screen.cols
        content_h = rows - 3
        lib_w = cols * @config["ui", "library_pane_percent"] / 100
        draw_box(0, 0, lib_w, content_h, active: @active_pane == :library, title: "Library")
        draw_box(lib_w, 0, cols - lib_w, content_h, active: @active_pane == :tracks, title: "Tracks")
        @library_pane.render(@screen, x: 1, y: 1, w: lib_w - 2, h: content_h - 2,
                             active: @active_pane == :library)
        @tracks_pane.render(@screen, x: lib_w + 1, y: 1, w: cols - lib_w - 2,
                            h: content_h - 2, active: @active_pane == :tracks)
        @playback_line.render(@screen, row: rows - 3, w: cols,
                              state: @engine.state, levels: @engine.levels)
        if @input_buffer
          @screen.put(rows - 2, 0, "Add path: #{@input_buffer}_"[0, cols], fg: :bright_yellow)
        else
          stats = @library.folder_stats
          @status_line.render(@screen, row: rows - 2, w: cols,
                              default: "#{stats[:tracks]} tracks in #{stats[:folders]} folders")
        end
        @hotkey_line.render(@screen, row: rows - 1, w: cols, pane: @active_pane)
        @screen.flush
      end

      def draw_box(x, y, w, h, active:, title:)
        color = active ? :bright_cyan : :bright_black
        @screen.put(y, x, "┌#{"─" * (w - 2)}┐", fg: color)
        (1...(h - 1)).each do |i|
          @screen.put(y + i, x, "│", fg: color)
          @screen.put(y + i, x + w - 1, "│", fg: color)
        end
        @screen.put(y + h - 1, x, "└#{"─" * (w - 2)}┘", fg: color)
        @screen.put(y, x + 2, " #{title} ", fg: color, bold: active)
      end

      # ---- terminal ----

      def setup_terminal
        $stdin.raw! if $stdin.tty?
        @io_out.write("\e[?1049h\e[?25l\e[?2004h") # alt screen, hide cursor, bracketed paste
      end

      def restore_terminal
        @io_out.write("\e[?2004l\e[?25h\e[?1049l")
        $stdin.cooked! if $stdin.tty?
      end

      def handle_resize
        @resized = false
        rows, cols = TTY::Screen.size
        @screen.resize(rows, cols)
      end
    end
  end
end
```

Logging (spec §10: file-based logs). Add to the bottom of `lib/rubyplayer/config.rb`
(inside `module RubyPlayer`, after the `data_dir` definition):
```ruby
  def self.logger
    @logger ||= begin
      require "logger"
      require "fileutils"
      FileUtils.mkdir_p(data_dir)
      Logger.new(File.join(data_dir, "rubyplayer.log"), 2, 1_048_576) # 2 rotations, 1MB
    end
  end
```

`bin/rubyplayer`:
```ruby
#!/usr/bin/env ruby
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "rubyplayer"
require "rubyplayer/ui/app"

begin
  RubyPlayer::UI::App.new(argv: ARGV).run
rescue StandardError => e
  # The TUI owns the screen; crashes go to the log where they can be read.
  RubyPlayer.logger.error("#{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
  raise
end
```
Then: `chmod +x bin/rubyplayer`

- [ ] **Step 5: Run tests**

Run: `bundle exec ruby -Itest test/app_test.rb`
Expected: `6 runs ... 0 failures, 0 errors`
Run the full suite: `bundle exec rake test`
Expected: all green.

- [ ] **Step 6: Manual end-to-end verification (real terminal + speakers)**

```bash
bin/rubyplayer fixtures
```
Verify, in order: (1) the two-pane UI appears with borders, the active pane bright;
(2) the status line reports the scan completing; (3) the fixtures folder appears with a
track count; (4) arrow keys navigate, right-arrow expands, `mega-man-2.nsf` shows as an
expandable multitrack folder; (5) TAB switches panes; (6) ENTER on a track plays audible
music; (7) SPACE pauses/resumes; (8) the EQ bars animate while playing; (9) `1`-`6` rates
the current track and Favorite Tracks reflects ratings >= 4; (10) `u` undoes an enqueue
and jumps to the Playback Queue; (11) ctrl_c exits cleanly, restoring the terminal.

- [ ] **Step 7: Commit**

```bash
git add bin/rubyplayer lib/rubyplayer.rb lib/rubyplayer/library.rb \
        lib/rubyplayer/ui/key_decoder.rb lib/rubyplayer/ui/app.rb \
        test/key_decoder_test.rb test/app_test.rb
git commit -m "feat: App main loop, key decoding, wiring + bin/rubyplayer entry point"
```

---

## Execution Order & Parallelism

Sequential is safest. If parallelizing with subagents, these groups are independent:
- After Task 4: Tasks 5, 11, 12, 13, 15, 16 are mutually independent.
- Tasks 6 and 7 are independent of each other (both need brew libs installed).
- Task 14 needs 5, 6, 8, 11. Tasks 17/18 need 4, 12, 16.
- Tasks 19 and 20 come last (20 strictly last).

## Phase 2 pointers (do NOT build now)

Archives (libarchive FFI), playlists (.m3u), the vgmstream backend, reacting to audio
device-rate changes, and missing/errored-track cleanup UI are Phase 2 — see spec §11.
The `archive_entry` column, the Registry's override/precedence hooks, and `Backend#open`
accepting a `source` are the prepared seams.
