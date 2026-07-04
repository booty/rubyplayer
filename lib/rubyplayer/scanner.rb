module RubyPlayer
  WorkItem = Struct.new(:path, :parent_folder_id, :status, keyword_init: true)

  # Phase-1 scan: filesystem walk + stat diff against the DB. Fast (never opens
  # music files). Returns WorkItems for the ExtractorPool (phase 2).
  class Scanner
    def initialize(library:, registry:)
      @library = library
      @registry = registry
    end

    def reconcile(root)
      root = File.expand_path(root)
      known = @library.db_paths_under(root)
      seen_tracks = {}
      seen_folders = {}
      work = []

      if File.directory?(root)
        root_id = @library.upsert_folder(parent_id: nil, name: File.basename(root),
                                         path: root, kind: "dir")
        seen_folders[root] = true
        walk(root, root_id, known, seen_tracks, seen_folders, work)
      elsif File.file?(root) && @registry.supported?(root)
        parent = File.dirname(root)
        parent_id = @library.upsert_folder(parent_id: nil, name: File.basename(parent),
                                           path: parent, kind: "dir")
        seen_folders[parent] = true
        diff_file(root, parent_id, known, seen_tracks, seen_folders, work)
      end

      missing_track_ids = known[:tracks].reject { |p, _| seen_tracks[p] }
                                        .values.flat_map { |v| v[:ids] }
      missing_folder_ids = known[:folders].reject { |p, _| seen_folders[p] }
                                          .values.map { |v| v[:id] }
      @library.mark_missing(track_ids: missing_track_ids, folder_ids: missing_folder_ids)
      work
    end

    private

    def walk(dir, dir_id, known, seen_tracks, seen_folders, work)
      Dir.children(dir).sort.each do |name|
        next if name.start_with?(".")
        path = File.join(dir, name)
        if File.directory?(path)
          id = @library.upsert_folder(parent_id: dir_id, name: name, path: path, kind: "dir")
          seen_folders[path] = true
          walk(path, id, known, seen_tracks, seen_folders, work)
        elsif File.file?(path) && @registry.supported?(path)
          diff_file(path, dir_id, known, seen_tracks, seen_folders, work)
        end
      end
    rescue Errno::EACCES, Errno::ENOENT
      # unreadable or vanished mid-walk: skip, never fatal
    end

    def diff_file(path, parent_folder_id, known, seen_tracks, seen_folders, work)
      seen_tracks[path] = true
      # a multi-subtune file also has a virtual folder row keyed by its path
      seen_folders[path] = true if @registry.multitrack?(path)
      stat = File.stat(path)
      existing = known[:tracks][path]
      if existing.nil?
        work << WorkItem.new(path: path, parent_folder_id: parent_folder_id, status: :new)
      elsif existing[:mtime] != stat.mtime.to_f || existing[:size] != stat.size
        work << WorkItem.new(path: path, parent_folder_id: parent_folder_id, status: :changed)
      end
    end
  end
end
