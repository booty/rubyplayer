require "etc"

module RubyPlayer
  # Phase-2 scan: bounded worker pool extracting metadata via FFI backends.
  # Parallelism is real because FFI calls release the GVL.
  class ExtractorPool
    def initialize(library:, registry:, thread_count: 0, event_bus: nil)
      @library = library
      @registry = registry
      @thread_count = thread_count.positive? ? thread_count : Etc.nprocessors
      @event_bus = event_bus
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
            @event_bus&.publish(:scan_progress, path: item.path)
          end
        end
      end
      threads.each(&:join)

      @library.recompute_counts!
      result = { processed: work_items.size, errored: errored }
      @event_bus&.publish(:scan_complete, **result)
      result
    end

    private

    def extract(item)
      stat = File.stat(item.path)
      backend = @registry.backend_for(item.path)
      count = @registry.multitrack?(item.path) ? backend.track_count(item.path) : 1
      if count > 1
        folder_id = @library.upsert_folder(parent_id: item.parent_folder_id,
                                           name: File.basename(item.path),
                                           path: item.path, kind: "multitrack",
                                           mtime: stat.mtime.to_f, size: stat.size)
        count.times do |i|
          upsert(item.path, folder_id, i, backend, backend.metadata(item.path, i), stat)
        end
      else
        upsert(item.path, item.parent_folder_id, 0, backend,
               backend.metadata(item.path, 0), stat)
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

    def upsert(path, folder_id, subtune, backend, meta, stat)
      @library.upsert_track(
        folder_id: folder_id, physical_path: path, subtune_index: subtune,
        backend: backend.name, format: meta[:format], title: meta[:title],
        album: meta[:album], artist: meta[:artist], composer: meta[:composer],
        track_number: meta[:track_number], duration_ms: meta[:duration_ms],
        file_mtime: stat.mtime.to_f, file_size: stat.size
      )
    end
  end
end
