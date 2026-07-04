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
