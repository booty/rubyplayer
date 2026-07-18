require "open3"

module RubyPlayer
  # Resolves cover art for a track: embedded artwork first (only for
  # ffmpeg-decoded formats — retro rips can't carry pictures), then
  # conventional image filenames in the track's folder. Archived tracks keep
  # physical_path = the archive file on disk, so its dirname is already the
  # right place to look without extracting anything.
  class Artwork
    DEFAULT_NAMES = %w[cover folder front albumart album].freeze
    IMAGE_EXTENSIONS = %w[jpg jpeg png gif].freeze

    def initialize(names: DEFAULT_NAMES, extractor: nil)
      @names = names
      @extractor = extractor || method(:extract_embedded)
      # Both caches are filled once per path and never invalidated: art on
      # disk changes far less often than tracks advance, and a stale hit
      # costs only an outdated picture until restart — while a miss costs a
      # process spawn (embedded) or a directory scan (folder) on every
      # track advance through an album.
      @embedded_cache = {}
      @folder_cache = {}
    end

    def for_track(track)
      embedded(track) || folder_art(File.dirname(track.physical_path))
    end

    # Average color of an image, as "#rrggbb": ffmpeg scales the whole frame
    # to a single pixel, which *is* the mean — no image library needed. Used
    # to tint the theme accent toward the current cover. Cached by content
    # hash since the same cover is re-fetched on every track advance through
    # an album.
    def average_color(bytes)
      @accent_cache ||= {}
      key = bytes.hash
      @accent_cache.fetch(key) do
        stdout, _stderr, status = Open3.capture3(
          "ffmpeg", "-hide_banner", "-loglevel", "error",
          "-i", "pipe:0", "-vf", "scale=1:1", "-frames:v", "1",
          "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1",
          stdin_data: bytes, binmode: true
        )
        @accent_cache[key] =
          if status.success? && stdout.bytesize >= 3
            format("#%02x%02x%02x", *stdout.bytes.first(3))
          end
      end
    rescue Errno::ENOENT
      nil
    end

    private

    def embedded(track)
      # Spawning ffmpeg on a gme/openmpt file would cost a process per track
      # only to learn the format cannot contain art.
      return nil unless track.backend == "ffmpeg"

      path = track.physical_path
      @embedded_cache.fetch(path) { @embedded_cache[path] = @extractor.call(path) }
    end

    # -c copy: the attached picture is already a complete JPEG/PNG stream;
    # copying it out avoids a re-encode and preserves the original bytes.
    def extract_embedded(path)
      stdout, _stderr, status = Open3.capture3(
        "ffmpeg", "-hide_banner", "-loglevel", "error",
        "-i", path, "-map", "0:v:0", "-frames:v", "1",
        "-c", "copy", "-f", "image2", "pipe:1",
        binmode: true
      )
      status.success? && !stdout.empty? ? stdout : nil
    rescue Errno::ENOENT
      nil
    end

    def folder_art(dir)
      @folder_cache.fetch(dir) { @folder_cache[dir] = read_folder_image(dir) }
    end

    def read_folder_image(dir)
      images = Dir.children(dir).select do |entry|
        IMAGE_EXTENSIONS.include?(File.extname(entry).delete_prefix(".").downcase)
      end
      return nil if images.empty?

      named = @names.filter_map { |name|
        images.find { |entry| File.basename(entry, ".*").downcase == name }
      }.first
      # .min (alphabetical) rather than .first: Dir.children order is
      # filesystem-dependent, and the fallback pick should be stable across
      # runs and machines.
      File.binread(File.join(dir, named || images.min))
    rescue SystemCallError
      nil
    end
  end
end
