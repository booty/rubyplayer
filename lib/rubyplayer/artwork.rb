# frozen_string_literal: true

require 'open3'

module RubyPlayer
  # Resolves cover art for a track: embedded artwork first (only for
  # ffmpeg-decoded formats — retro rips can't carry pictures), then
  # conventional image filenames in the track's folder. An archived track
  # (physical_path is the archive) looks beside its entry inside the
  # archive first, since rip zips often pack their own cover, then in the
  # archive's own folder.
  class Artwork
    DEFAULT_NAMES = %w[cover folder front albumart album].freeze
    IMAGE_EXTENSIONS = %w[jpg jpeg png gif].freeze

    def initialize(names: DEFAULT_NAMES, extractor: nil, archive_cache: nil)
      @names = names
      @extractor = extractor || method(:extract_embedded)
      @archive_cache = archive_cache
      # Both caches are filled once per path and never invalidated: art on
      # disk changes far less often than tracks advance, and a stale hit
      # costs only an outdated picture until restart — while a miss costs a
      # process spawn (embedded) or a directory scan (folder) on every
      # track advance through an album.
      @embedded_cache = {}
      @folder_cache = {}
    end

    def for_track(track)
      embedded(track) || archived_art(track) || folder_art(File.dirname(track.physical_path))
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
          'ffmpeg', '-hide_banner', '-loglevel', 'error',
          '-i', 'pipe:0', '-vf', 'scale=1:1', '-frames:v', '1',
          '-f', 'rawvideo', '-pix_fmt', 'rgb24', 'pipe:1',
          stdin_data: bytes, binmode: true
        )
        @accent_cache[key] =
          (format('#%02x%02x%02x', *stdout.bytes.first(3)) if status.success? && stdout.bytesize >= 3)
      end
    rescue Errno::ENOENT
      nil
    end

    # Bounded PNG copy for terminal display. A normalized format means the
    # terminal renderer never needs format-specific handling, and limiting
    # dimensions keeps the one upload small enough for terminal protocols.
    def display_bytes(bytes, max_px:)
      @display_cache ||= {}
      key = [bytes.hash, max_px]
      @display_cache.fetch(key) { @display_cache[key] = display_png(bytes, max_px) }
    end

    private

    def display_png(bytes, max_px)
      return nil unless max_px.to_i.positive?

      bounded = "scale=w='min(#{max_px},iw)':h='min(#{max_px},ih)':force_original_aspect_ratio=decrease"
      png, _stderr, status = Open3.capture3(
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', 'pipe:0', '-vf', bounded, '-frames:v', '1',
        '-f', 'image2pipe', '-c:v', 'png', 'pipe:1',
        stdin_data: bytes, binmode: true
      )
      status.success? && png.start_with?("\x89PNG\r\n\x1a\n".b) ? png : nil
    rescue Errno::ENOENT
      nil
    end

    def embedded(track)
      # Spawning ffmpeg on a gme/openmpt file would cost a process per track
      # only to learn the format cannot contain art.
      return nil unless track.backend == 'ffmpeg'

      path = track.physical_path
      @embedded_cache.fetch(path) { @embedded_cache[path] = @extractor.call(path) }
    end

    # -c copy: the attached picture is already a complete JPEG/PNG stream;
    # copying it out avoids a re-encode and preserves the original bytes.
    def extract_embedded(path)
      stdout, _stderr, status = Open3.capture3(
        'ffmpeg', '-hide_banner', '-loglevel', 'error',
        '-i', path, '-map', '0:v:0', '-frames:v', '1',
        '-c', 'copy', '-f', 'image2', 'pipe:1',
        binmode: true
      )
      status.success? && !stdout.empty? ? stdout : nil
    rescue Errno::ENOENT
      nil
    end

    # The folder holding the track's entry inside its extracted archive.
    # Scanning already extracted it, so this is normally a cache hit; it runs
    # off the UI thread regardless.
    def archived_art(track)
      entry = track.archive_entry.to_s
      return nil if entry.empty? || @archive_cache.nil?

      folder_art(File.dirname(@archive_cache.materialize(track.physical_path, entry)))
    rescue ArchiveCache::ExtractError, SystemCallError
      nil
    end

    def folder_art(dir)
      @folder_cache.fetch(dir) { @folder_cache[dir] = read_folder_image(dir) }
    end

    def read_folder_image(dir)
      # "._name" files are macOS AppleDouble metadata stubs, not images.
      images = Dir.children(dir).select do |entry|
        !entry.start_with?('._') && IMAGE_EXTENSIONS.include?(File.extname(entry).delete_prefix('.').downcase)
      end
      return nil if images.empty?

      named = @names.filter_map do |name|
        images.find { |entry| File.basename(entry, '.*').downcase == name }
      end.first
      # .min (alphabetical) rather than .first: Dir.children order is
      # filesystem-dependent, and the fallback pick should be stable across
      # runs and machines.
      File.binread(File.join(dir, named || images.min))
    rescue SystemCallError
      nil
    end
  end
end
