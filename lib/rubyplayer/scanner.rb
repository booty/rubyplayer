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
      return diff_archive(path, parent_folder_id, known, seen_tracks, seen_folders, work) if @registry.archive?(path)
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

    # Archives are stat-diffed like plain files (extraction is the pool's
    # phase-2 job), but their DB footprint is a whole subtree: inner tracks
    # all share the archive's physical_path, and inner folders live at
    # "archive_path/entry" paths that never exist on disk.
    def diff_archive(path, parent_folder_id, known, seen_tracks, seen_folders, work)
      seen_folders[path] = true # the archive's own "archive"-kind folder row
      stat = File.stat(path)
      # Diff against the archive's folder row, not its track rows: an archive
      # holding only unsupported formats has zero tracks but still gets a
      # folder row, and must not be re-extracted on every rescan.
      existing = known[:folders][path]
      changed = existing.nil? || existing[:mtime] != stat.mtime.to_f || existing[:size] != stat.size
      if changed
        work << WorkItem.new(path: path, parent_folder_id: parent_folder_id,
                             status: existing.nil? ? :new : :changed)
        # Inner rows stay unseen on purpose: mark_missing flags them all, and
        # the pool's re-extraction upserts restore the ones still present in
        # the new archive version (missing=0 on conflict) -- entries that were
        # removed from the archive stay missing. Runs are sequential (phase 1
        # reconcile finishes before phase 2 extraction), so no race.
      else
        seen_tracks[path] = true
        prefix = "#{path}/"
        known[:folders].each_key { |p| seen_folders[p] = true if p.start_with?(prefix) }
      end
    end
  end
end
