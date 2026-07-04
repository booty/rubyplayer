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
