require "test_helper"
require "tmpdir"
require "fileutils"

class ArchiveCacheTest < Minitest::Test
  FIXTURES = File.expand_path("../fixtures", __dir__)

  def setup
    @tmp = Dir.mktmpdir
    @cache = RubyPlayer::ArchiveCache.new(root: File.join(@tmp, "cache"))
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_extracts_zip_and_returns_dir_with_entries
    dir = @cache.extract(File.join(FIXTURES, "musha.zip"))
    entries = Dir.children(dir).sort
    assert_includes entries, "10 - Round Clear.vgm"
    assert_includes entries, "11 - Game Over.vgm"
  end

  def test_extracts_7z
    dir = @cache.extract(File.join(FIXTURES, "phantasy.7z"))
    assert_includes Dir.children(dir), "01 - Phantasy.vgm"
  end

  def test_extracts_rar
    dir = @cache.extract(File.join(FIXTURES, "phantasy.rar"))
    assert_includes Dir.children(dir), "04 - My Home.vgm"
  end

  def test_extract_is_cached_and_stable
    src = File.join(FIXTURES, "musha.zip")
    dir1 = @cache.extract(src)
    canary = File.join(dir1, "canary")
    File.write(canary, "x")
    dir2 = @cache.extract(src)
    assert_equal dir1, dir2
    assert File.exist?(canary), "second extract must not re-unpack a complete cache entry"
  end

  def test_incomplete_cache_entry_is_re_extracted
    src = File.join(FIXTURES, "musha.zip")
    dir = @cache.extract(src)
    FileUtils.rm(Dir.glob(File.join(@cache.root, "**", ".complete")))
    victim = File.join(dir, "10 - Round Clear.vgm")
    FileUtils.rm(victim)
    @cache.extract(src)
    assert File.exist?(victim), "missing .complete marker must force re-extraction"
  end

  def test_extract_raises_on_unreadable_archive
    bad = File.join(@tmp, "corrupt.zip")
    File.write(bad, "not a zip at all")
    assert_raises(RubyPlayer::ArchiveCache::ExtractError) { @cache.extract(bad) }
  end

  def test_materialize_returns_physical_path_when_entry_empty
    assert_equal "/x/a.vgm", @cache.materialize("/x/a.vgm", "")
    assert_equal "/x/a.vgm", @cache.materialize("/x/a.vgm", nil)
  end

  def test_materialize_resolves_entry_to_extracted_file
    src = File.join(FIXTURES, "musha.zip")
    path = @cache.materialize(src, "10 - Round Clear.vgm")
    assert File.exist?(path)
    assert path.start_with?(@cache.root)
  end

  def test_materialize_resolves_nested_archive_chain
    # nested.zip contains musha.zip; entry chains through it
    nested = File.join(@tmp, "nested.zip")
    system("bsdtar", "-cf", nested, "--format", "zip",
           "-C", FIXTURES, "musha.zip", exception: true)
    path = @cache.materialize(nested, "musha.zip/11 - Game Over.vgm")
    assert File.exist?(path)
    assert_equal "11 - Game Over.vgm", File.basename(path)
  end
end
