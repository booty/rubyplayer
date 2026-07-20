require "test_helper"
require "tmpdir"
require "fileutils"

# Minimal stand-ins for Backends::Registry / a backend instance so album
# fallback and KV-persistence tests can control #metadata precisely without
# depending on what real fixture files happen to tag.
class FakeBackend
  attr_reader :name

  def initialize(name, metadata: {}, track_counts: {})
    @name = name
    @metadata = metadata
    @track_counts = track_counts
  end

  def track_count(path) = @track_counts.fetch(path, 1)

  def metadata(path, subtune_index)
    @metadata.fetch([path, subtune_index]) { @metadata.fetch(path, {}) }
  end
end

class FakeRegistry
  def initialize(backend:, multitrack_paths: [], archive_paths: [])
    @backend = backend
    @multitrack_paths = multitrack_paths
    @archive_paths = archive_paths
  end

  def archive?(path) = @archive_paths.include?(path)
  def multitrack?(path) = @multitrack_paths.include?(path)
  def supported?(_path) = true
  def backend_for(_path) = @backend
  def backend_name_for(_path) = @backend.name
end

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
    # musha.zip's entries carry an explicit GME "game" tag ("M.U.S.H.A."); the
    # ingest-time album fallback (meta[:album] || album_fallback) must not
    # clobber it with the archive basename.
    assert_equal ["M.U.S.H.A."], rows.map { |r| r["album"] }.uniq
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

  def root_folder_id
    @lib.upsert_folder(parent_id: nil, name: "music", path: @music, kind: "dir")
  end

  def track_row(path)
    @db.read { |s| s.execute("SELECT * FROM tracks WHERE physical_path = ?", [path]).first }
  end

  def test_album_falls_back_to_parent_folder_for_plain_files
    dir = File.join(@music, "Zelda Rips")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new("fake", metadata: { path => { title: "Song", format: "vgm", album: nil } })
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)

    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    result = pool.process(work)

    assert_equal 1, result[:processed]
    assert_equal 0, result[:errored]
    assert_equal "Zelda Rips", track_row(path)["album"]
  end

  def test_album_falls_back_to_container_name_for_multitrack
    path = File.join(@music, "game.nsf")
    File.write(path, "fake nsf data")
    backend = FakeBackend.new(
      "fake",
      metadata: {
        [path, 0] => { title: "Track 1", format: "nsf", album: nil },
        [path, 1] => { title: "Track 2", format: "nsf", album: nil }
      },
      track_counts: { path => 2 }
    )
    registry = FakeRegistry.new(backend: backend, multitrack_paths: [path])
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)

    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)

    rows = @db.read { |s| s.execute("SELECT * FROM tracks WHERE physical_path = ? ORDER BY subtune_index", [path]) }
    assert_equal 2, rows.size
    assert_equal ["game", "game"], rows.map { |r| r["album"] }
  end

  def test_explicit_album_tag_wins_over_fallback
    dir = File.join(@music, "Some Folder")
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new("fake", metadata: { path => { title: "Song", format: "vgm", album: "Real Album" } })
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)

    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)

    assert_equal "Real Album", track_row(path)["album"]
  end

  def test_extra_tags_persist_to_track_metadata
    path = File.join(@music, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new(
      "fake",
      metadata: { path => { title: "Song", format: "vgm", album: "Album", extra: { "genre" => "VGM" } } }
    )
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)

    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)

    track_id = track_row(path)["id"]
    assert_equal({ "genre" => "VGM" }, @lib.track_metadata_for(track_id))
  end

  def test_no_extra_tags_leaves_track_metadata_empty
    path = File.join(@music, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new("fake", metadata: { path => { title: "Song", format: "vgm", album: "Album" } })
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)

    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)

    track_id = track_row(path)["id"]
    assert_empty @lib.track_metadata_for(track_id)
  end

  # Bug: upsert only called replace_track_metadata when extras was truthy AND
  # non-empty, so a rescan where the backend now reports extra: {} (all extra
  # tags removed from the file) left the previous scan's KV rows in place —
  # contradicts "scan is the single source of truth" for file-derived metadata.
  def test_rescan_with_now_empty_extras_clears_stale_track_metadata
    path = File.join(@music, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new(
      "fake",
      metadata: { path => { title: "Song", format: "vgm", album: "Album", extra: { "genre" => "VGM" } } }
    )
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)
    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)
    track_id = track_row(path)["id"]
    assert_equal({ "genre" => "VGM" }, @lib.track_metadata_for(track_id))

    # rescan: file was retagged to drop all extra tags
    rescan_backend = FakeBackend.new(
      "fake",
      metadata: { path => { title: "Song", format: "vgm", album: "Album", extra: {} } }
    )
    rescan_registry = FakeRegistry.new(backend: rescan_backend)
    rescan_pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: rescan_registry, thread_count: 1)
    rescan_pool.process(work)

    assert_empty @lib.track_metadata_for(track_id)
  end

  # A backend with no :extra concept at all (gme/openmpt) must never touch
  # track_metadata, including across a rescan where other fields changed.
  def test_rescan_without_extra_key_leaves_existing_track_metadata_untouched
    path = File.join(@music, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new(
      "fake",
      metadata: { path => { title: "Song", format: "vgm", album: "Album", extra: { "genre" => "VGM" } } }
    )
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)
    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)
    track_id = track_row(path)["id"]
    assert_equal({ "genre" => "VGM" }, @lib.track_metadata_for(track_id))

    # rescan with a backend that has no :extra key at all
    no_extra_backend = FakeBackend.new(
      "fake",
      metadata: { path => { title: "Song 2", format: "vgm", album: "Album" } }
    )
    no_extra_registry = FakeRegistry.new(backend: no_extra_backend)
    no_extra_pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: no_extra_registry, thread_count: 1)
    no_extra_pool.process(work)

    assert_equal({ "genre" => "VGM" }, @lib.track_metadata_for(track_id))
  end

  def test_album_artist_and_year_flow_through_upsert
    path = File.join(@music, "song.vgm")
    File.write(path, "fake vgm data")
    backend = FakeBackend.new(
      "fake",
      metadata: { path => { title: "Song", format: "vgm", album: "Album", album_artist: "V.A.", year: 2001 } }
    )
    registry = FakeRegistry.new(backend: backend)
    pool = RubyPlayer::ExtractorPool.new(library: @lib, registry: registry, thread_count: 1)

    work = [RubyPlayer::WorkItem.new(path: path, parent_folder_id: root_folder_id, status: :new)]
    pool.process(work)

    row = track_row(path)
    assert_equal "V.A.", row["album_artist"]
    assert_equal 2001, row["year"]
  end
end
