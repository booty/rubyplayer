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
