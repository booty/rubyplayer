require "etc"

module RubyPlayer
  # Phase-2 scan: bounded worker pool extracting metadata via FFI backends.
  # Parallelism is real because FFI calls release the GVL.
  class ExtractorPool
    def initialize(library:, registry:, thread_count: 0, event_bus: nil, archive_cache: nil)
      @library = library
      @registry = registry
      @thread_count = thread_count.positive? ? thread_count : Etc.nprocessors
      @event_bus = event_bus
      @archive_cache = archive_cache
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
            # Progress notification is telemetry, not core work: a raising bus must
            # not escape the worker thread, or Thread#join re-raises it and skips
            # recompute_counts!/:scan_complete while leaving sibling workers orphaned.
            safe_publish(:scan_progress, path: item.path)
          end
        end
      end
      threads.each(&:join)

      @library.recompute_counts!
      result = { processed: work_items.size, errored: errored }
      safe_publish(:scan_complete, **result)
      result
    end

    private

    # The pool's contract is "never raises out of #process"; a caller-supplied
    # event_bus is outside our control, so any exception from #publish is
    # swallowed here rather than allowed to propagate.
    def safe_publish(...)
      @event_bus&.publish(...)
    rescue StandardError
      nil
    end

    def extract(item)
      stat = File.stat(item.path)
      return extract_archive(item, stat) if @registry.archive?(item.path)
      backend = @registry.backend_for(item.path)
      count = @registry.multitrack?(item.path) ? backend.track_count(item.path) : 1
      if count > 1
        folder_id = @library.upsert_folder(parent_id: item.parent_folder_id,
                                           name: File.basename(item.path),
                                           path: item.path, kind: "multitrack",
                                           mtime: stat.mtime.to_f, size: stat.size)
        count.times do |i|
          upsert(item.path, folder_id, i, backend, backend.metadata(item.path, i), stat,
                 album_fallback: File.basename(item.path, ".*"))
        end
      else
        upsert(item.path, item.parent_folder_id, 0, backend,
               backend.metadata(item.path, 0), stat,
               album_fallback: File.basename(File.dirname(item.path)))
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

    def upsert(path, folder_id, subtune, backend, meta, stat, archive_entry: "",
               album_fallback: nil)
      track_id = @library.upsert_track(
        folder_id: folder_id, physical_path: path, archive_entry: archive_entry,
        subtune_index: subtune,
        backend: backend.name, format: meta[:format], title: meta[:title],
        # Fallback is baked at ingest so SQL ORDER BY, Ruby sorts, and the
        # live filter all see the same value (render-time fallback would
        # give SQL-ordered views a different order than the pane shows).
        album: meta[:album] || album_fallback,
        artist: meta[:artist], composer: meta[:composer],
        album_artist: meta[:album_artist], year: meta[:year],
        track_number: meta[:track_number], duration_ms: meta[:duration_ms],
        file_mtime: stat.mtime.to_f, file_size: stat.size
      )
      extras = meta[:extra]
      @library.replace_track_metadata(track_id, extras) if extras && !extras.empty?
      track_id
    end

    # An archive becomes an "archive"-kind folder whose descendants are its
    # entries. Track rows keep physical_path = the archive file (so the
    # Scanner's one stat diffs the whole subtree) and put the inner path in
    # archive_entry; folder rows use virtual "archive_path/entry" paths.
    def extract_archive(item, stat)
      dir = @archive_cache.extract(item.path)
      folder_id = @library.upsert_folder(parent_id: item.parent_folder_id,
                                         name: File.basename(item.path), path: item.path,
                                         kind: "archive", mtime: stat.mtime.to_f, size: stat.size)
      walk_extracted(dir, folder_id, item.path, "", stat)
      true
    end

    def walk_extracted(dir, folder_id, archive_path, entry_prefix, stat)
      Dir.children(dir).sort.each do |name|
        next if name.start_with?(".") # includes the cache's .complete marker
        real = File.join(dir, name)
        entry = entry_prefix.empty? ? name : "#{entry_prefix}/#{name}"
        virtual = "#{archive_path}/#{entry}"
        if File.directory?(real)
          id = @library.upsert_folder(parent_id: folder_id, name: name, path: virtual, kind: "dir")
          walk_extracted(real, id, archive_path, entry, stat)
        elsif @registry.archive?(real)
          # nested archive: its own cache entry, but tracks still hang off the
          # OUTER archive's physical_path with a chained entry ("a.zip/b.vgm")
          id = @library.upsert_folder(parent_id: folder_id, name: name, path: virtual,
                                      kind: "archive")
          walk_extracted(@archive_cache.extract(real), id, archive_path, entry, stat)
        elsif @registry.supported?(real)
          extract_entry(real, entry, virtual, folder_id, archive_path, stat)
        end
      end
    end

    def extract_entry(real, entry, virtual, folder_id, archive_path, stat)
      backend = @registry.backend_for(real)
      count = @registry.multitrack?(real) ? backend.track_count(real) : 1
      if count > 1
        sub_id = @library.upsert_folder(parent_id: folder_id, name: File.basename(real),
                                        path: virtual, kind: "multitrack",
                                        mtime: stat.mtime.to_f, size: stat.size)
        count.times do |i|
          upsert(archive_path, sub_id, i, backend, backend.metadata(real, i), stat,
                 archive_entry: entry, album_fallback: File.basename(archive_path, ".*"))
        end
      else
        upsert(archive_path, folder_id, 0, backend, backend.metadata(real, 0), stat,
               archive_entry: entry, album_fallback: File.basename(archive_path, ".*"))
      end
    rescue StandardError
      # One undecodable entry must not sink the whole archive.
      @library.upsert_track(
        folder_id: folder_id, physical_path: archive_path, archive_entry: entry,
        backend: @registry.backend_name_for(real).to_s,
        format: File.extname(real).delete_prefix(".").downcase,
        title: File.basename(entry), errored: 1,
        file_mtime: stat.mtime.to_f, file_size: stat.size
      )
    end
  end
end
