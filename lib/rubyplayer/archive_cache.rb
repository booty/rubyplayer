require "digest"
require "fileutils"
require "open3"

module RubyPlayer
  # Extracts archive containers (.zip/.7z/.rar) into a content-addressed
  # on-disk cache so the FFI backends -- which can only read real files --
  # can decode entries stored inside archives.
  #
  # bsdtar (libarchive, bundled with macOS) is the extractor because one
  # tool reads all three formats and, unless given -P, it refuses absolute
  # paths and ".." components in entry names -- so a malicious archive
  # cannot write outside its cache directory (zip-slip).
  class ArchiveCache
    class ExtractError < StandardError; end

    # Cache entries are keyed by path+mtime+size, so a re-downloaded or
    # edited archive naturally gets a fresh entry instead of stale contents.
    MARKER = ".complete"

    attr_reader :root

    def initialize(root:, tar: "bsdtar")
      @root = root
      @tar = tar
    end

    # Returns the directory the archive's contents live in, extracting on
    # first use. A MARKER file distinguishes a finished extraction from one
    # that crashed midway (partial dirs are wiped and redone).
    def extract(archive_path)
      dir = File.join(@root, cache_key(archive_path))
      return dir if File.exist?(File.join(dir, MARKER))

      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      _out, err, status = Open3.capture3(@tar, "-xf", archive_path, "-C", dir)
      unless status.success?
        FileUtils.rm_rf(dir)
        raise ExtractError, "#{@tar} failed on #{archive_path}: #{err.lines.first&.strip}"
      end
      FileUtils.touch(File.join(dir, MARKER))
      dir
    end

    # Resolves a track's (physical_path, archive_entry) pair to a real file.
    # entry components that are themselves archives ("nested.zip/a.vgm") are
    # extracted along the way, so arbitrarily nested containers work.
    def materialize(physical_path, entry)
      return physical_path if entry.nil? || entry.empty?

      current = extract(physical_path)
      parts = entry.split("/")
      parts.each_with_index do |part, i|
        current = File.join(current, part)
        # A *file* with an archive extension mid-chain is a nested archive;
        # a real directory that merely ends in ".zip" falls through as a dir.
        if i < parts.size - 1 && File.file?(current) && archive_ext?(current)
          current = extract(current)
        end
      end
      current
    end

    private

    def archive_ext?(path)
      Backends::Registry::ARCHIVE_EXTS.include?(File.extname(path).downcase)
    end

    def cache_key(archive_path)
      stat = File.stat(archive_path)
      digest = Digest::SHA1.hexdigest("#{archive_path}:#{stat.mtime.to_f}:#{stat.size}")[0, 16]
      # basename prefix keeps the cache dir human-debuggable
      "#{File.basename(archive_path)}-#{digest}"
    end
  end
end
