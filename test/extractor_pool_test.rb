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

  def archive_pool
    RubyPlayer::ExtractorPool.new(
      library: @lib, registry: @reg, thread_count: 2,
      archive_cache: RubyPlayer::ArchiveCache.new(root: File.join(@tmp, "cache"))
    )
  end

  def test_archive_becomes_folder_with_entry_tracks
    FileUtils.cp(File.join(FIXTURES, "musha.zip"), @music)
    zip = File.join(@music, "musha.zip")
    archive_pool.process(@scanner.reconcile(@music))

    arc = @db.read { |s| s.execute("SELECT * FROM folders WHERE kind = 'archive'").first }
    refute_nil arc
    assert_equal zip, arc["path"]

    rows = @db.read { |s| s.execute("SELECT * FROM tracks WHERE physical_path = ? ORDER BY archive_entry", [zip]) }
    assert_equal ["10 - Round Clear.vgm", "11 - Game Over.vgm", "17 - Puyo Puyo Bonus SE.vgm"],
                 rows.map { |r| r["archive_entry"] }
    assert_equal ["gme"], rows.map { |r| r["backend"] }.uniq
    assert(rows.all? { |r| r["duration_ms"].to_i.positive? })
    # entries inherit the archive's stat so the scanner's diff pass works
    stat = File.stat(zip)
    assert_equal [stat.mtime.to_f], rows.map { |r| r["file_mtime"] }.uniq
    # idempotency: rescan after extraction finds nothing to do
    assert_empty @scanner.reconcile(@music)
  end

  def test_rar_and_7z_archives_extract_too
    FileUtils.cp(File.join(FIXTURES, "phantasy.7z"), @music)
    FileUtils.cp(File.join(FIXTURES, "phantasy.rar"), @music)
    result = archive_pool.process(@scanner.reconcile(@music))
    assert_equal 0, result[:errored] - 1 # corrupt.mod is the only error
    entries = @db.read { |s| s.execute("SELECT archive_entry FROM tracks WHERE archive_entry != ''") }
                 .map { |r| r["archive_entry"] }
    assert_includes entries, "01 - Phantasy.vgm" # from the 7z
    assert_includes entries, "04 - My Home.vgm"  # from the rar
  end

  def test_nested_archive_entries_chain_through_inner_archive
    nested = File.join(@music, "nested.zip")
    system("bsdtar", "-cf", nested, "--format", "zip",
           "-C", FIXTURES, "musha.zip", exception: true)
    archive_pool.process(@scanner.reconcile(@music))

    inner = @db.read { |s| s.execute("SELECT * FROM folders WHERE path = ?", ["#{nested}/musha.zip"]).first }
    refute_nil inner
    assert_equal "archive", inner["kind"]

    rows = @db.read { |s| s.execute("SELECT archive_entry FROM tracks WHERE physical_path = ?", [nested]) }
    assert_includes rows.map { |r| r["archive_entry"] }, "musha.zip/10 - Round Clear.vgm"
  end

  def test_unreadable_archive_flags_errored_track
    File.write(File.join(@music, "corrupt.zip"), "not an archive")
    result = archive_pool.process(@scanner.reconcile(@music))
    assert_equal 2, result[:errored] # corrupt.mod + corrupt.zip
    bad = @db.read { |s| s.execute("SELECT * FROM tracks WHERE physical_path LIKE '%corrupt.zip'").first }
    assert_equal 1, bad["errored"]
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
