require "time"

module RubyPlayer
  class Library
    def initialize(db)
      @db = db
    end

    # Playlists are user curation, not disk state: the library's soft-delete
    # philosophy does not apply, so deletes are hard and cascade.
    PlaylistError = Class.new(StandardError)
    PlaylistNameTaken = Class.new(PlaylistError)

    def playlists(sort: :recency)
      order = sort == :alpha ? "name COLLATE NOCASE" : "updated_at DESC"
      @db.read do |s|
        s.execute(<<~SQL)
          SELECT p.*, (
            SELECT COUNT(*) FROM playlist_tracks pt
            JOIN tracks t ON t.id = pt.track_id
            WHERE pt.playlist_id = p.id AND t.missing = 0
          ) AS track_count
          FROM playlists p ORDER BY #{order}
        SQL
      end
    end

    def create_playlist(name)
      # Microsecond precision: recency ordering must distinguish two edits in
      # the same second (whole-second timestamps made the sort a coin flip).
      now = Time.now.utc.iso8601(6)
      @db.write do |s|
        s.execute("INSERT INTO playlists (name, created_at, updated_at) VALUES (?, ?, ?)",
                  [name, now, now])
        s.get_first_value("SELECT id FROM playlists WHERE name = ?", [name])
      end
    rescue SQLite3::ConstraintException
      raise PlaylistNameTaken, "A playlist named \"#{name}\" already exists"
    end

    def rename_playlist(id, name)
      @db.write do |s|
        s.execute("UPDATE playlists SET name = ?, updated_at = ? WHERE id = ?",
                  [name, Time.now.utc.iso8601(6), id])
      end
    rescue SQLite3::ConstraintException
      raise PlaylistNameTaken, "A playlist named \"#{name}\" already exists"
    end

    def delete_playlist(id)
      @db.write { |s| s.execute("DELETE FROM playlists WHERE id = ?", [id]) }
    end

    def add_to_playlist(id, track_id)
      @db.write do |s|
        pos = s.get_first_value(
          "SELECT COALESCE(MAX(position) + 1, 0) FROM playlist_tracks WHERE playlist_id = ?", [id]
        )
        s.execute("INSERT INTO playlist_tracks (playlist_id, track_id, position) VALUES (?, ?, ?)",
                  [id, track_id, pos])
        s.execute("UPDATE playlists SET updated_at = ? WHERE id = ?",
                  [Time.now.utc.iso8601(6), id])
      end
    rescue SQLite3::ConstraintException
      # FK failure: the track was hard-purged while the add modal was open.
      raise PlaylistError, "Track is no longer in the library"
    end

    def playlist_contains?(id, track_id)
      !!@db.read do |s|
        s.get_first_value(
          "SELECT 1 FROM playlist_tracks WHERE playlist_id = ? AND track_id = ? LIMIT 1",
          [id, track_id]
        )
      end
    end

    def upsert_folder(parent_id:, name:, path:, kind:, mtime: nil, size: nil)
      @db.write do |s|
        s.execute(<<~SQL, [parent_id, name, path, kind, mtime, size, Time.now.utc.iso8601])
          INSERT INTO folders (parent_id, name, path, kind, mtime, size, last_scanned_at)
          VALUES (?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(path) DO UPDATE SET
            parent_id=excluded.parent_id, name=excluded.name, kind=excluded.kind,
            mtime=excluded.mtime, size=excluded.size,
            last_scanned_at=excluded.last_scanned_at, missing=0
        SQL
        s.get_first_value("SELECT id FROM folders WHERE path = ?", [path])
      end
    end

    def upsert_track(attrs)
      a = { archive_entry: "", subtune_index: 0, errored: 0,
            file_mtime: nil, file_size: nil }.merge(attrs)
      now = Time.now.utc.iso8601
      sql = <<~SQL
        INSERT INTO tracks (folder_id, physical_path, archive_entry, subtune_index,
                            backend, format, title, album, artist, composer,
                            track_number, duration_ms, file_mtime, file_size,
                            errored, added_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(physical_path, archive_entry, subtune_index) DO UPDATE SET
          folder_id=excluded.folder_id, backend=excluded.backend, format=excluded.format,
          title=excluded.title, album=excluded.album, artist=excluded.artist,
          composer=excluded.composer, track_number=excluded.track_number,
          duration_ms=excluded.duration_ms, file_mtime=excluded.file_mtime,
          file_size=excluded.file_size, errored=excluded.errored,
          missing=0, updated_at=excluded.updated_at
      SQL
      @db.write do |s|
        s.execute(sql, [a[:folder_id], a[:physical_path], a[:archive_entry], a[:subtune_index],
                        a[:backend], a[:format], a[:title], a[:album], a[:artist], a[:composer],
                        a[:track_number], a[:duration_ms], a[:file_mtime], a[:file_size],
                        a[:errored], now, now])
        s.get_first_value(
          "SELECT id FROM tracks WHERE physical_path = ? AND archive_entry = ? AND subtune_index = ?",
          [a[:physical_path], a[:archive_entry], a[:subtune_index]]
        )
      end
    end

    def roots
      visible_folders("parent_id IS NULL")
    end

    def children_of(folder_id)
      visible_folders("parent_id = ?", [folder_id])
    end

    def tracks_under(folder_id)
      rows = @db.read do |s|
        s.execute(<<~SQL, [folder_id])
          WITH RECURSIVE sub(id) AS (
            SELECT id FROM folders WHERE id = ?
            UNION ALL
            SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id
          )
          SELECT t.* FROM tracks t
          WHERE t.folder_id IN (SELECT id FROM sub) AND t.missing = 0
          ORDER BY t.physical_path, t.subtune_index
        SQL
      end
      rows.map { |r| Track.from_row(r) }
    end

    def all_tracks
      query_tracks("missing = 0 ORDER BY physical_path, subtune_index")
    end

    def favorites
      query_tracks("rating >= 4 AND missing = 0 ORDER BY rating DESC, title")
    end

    # Smart views stay as direct queries rather than cached collections so
    # scanner, rating, and playback-history changes appear on next pane reload.
    def recently_added
      query_tracks("missing = 0 ORDER BY added_at DESC, title COLLATE NOCASE")
    end

    def unrated
      query_tracks("missing = 0 AND rating IS NULL ORDER BY title COLLATE NOCASE")
    end

    def missing_tracks
      query_tracks("missing = 1 ORDER BY physical_path, title COLLATE NOCASE")
    end

    def failed_tracks
      # Deliberately includes missing rows: failure and file presence describe
      # independent states, and Failed to Scan is diagnostic rather than playable.
      query_tracks("errored = 1 ORDER BY physical_path, title COLLATE NOCASE")
    end

    def purge_missing_tracks!(ids)
      requested = Array(ids).map(&:to_i).uniq
      return [] if requested.empty?

      placeholders = (["?"] * requested.size).join(",")
      deleted = @db.write do |db|
        # Re-check missing inside same transaction as deletion. UI targets can
        # become stale if scanner restores a file while confirmation is open.
        actual = db.execute(
          "SELECT id FROM tracks WHERE missing = 1 AND id IN (#{placeholders})",
          requested
        ).map { |row| row["id"] }
        next [] if actual.empty?

        actual_placeholders = (["?"] * actual.size).join(",")
        db.execute("DELETE FROM playback_history WHERE track_id IN (#{actual_placeholders})", actual)
        db.execute("DELETE FROM track_metadata WHERE track_id IN (#{actual_placeholders})", actual)
        db.execute("DELETE FROM tracks WHERE id IN (#{actual_placeholders})", actual)
        actual
      end
      recompute_counts! unless deleted.empty?
      deleted
    end

    def most_played
      rows = @db.read do |s|
        s.execute(<<~SQL)
          SELECT t.*
          FROM tracks t JOIN playback_history h ON h.track_id = t.id
          WHERE t.missing = 0
          GROUP BY t.id
          ORDER BY COUNT(h.id) DESC,
                   SUM((julianday(h.ended_at) - julianday(h.started_at)) * 86400000) DESC,
                   t.title COLLATE NOCASE
        SQL
      end
      rows.map { |row| Track.from_row(row) }
    end

    def history(limit: 100)
      rows = @db.read do |s|
        s.execute(<<~SQL, [limit])
          SELECT h.started_at, h.ended_at, t.*
          FROM playback_history h JOIN tracks t ON t.id = h.track_id
          ORDER BY h.started_at DESC LIMIT ?
        SQL
      end
      rows.map { |r| { track: Track.from_row(r), started_at: r["started_at"], ended_at: r["ended_at"] } }
    end

    def record_history(track_id:, started_at:, ended_at:)
      @db.write do |s|
        s.execute("INSERT INTO playback_history (track_id, started_at, ended_at) VALUES (?, ?, ?)",
                  [track_id, started_at, ended_at])
      end
    end

    def set_rating(track_id, rating)
      @db.write { |s| s.execute("UPDATE tracks SET rating = ? WHERE id = ?", [rating, track_id]) }
    end

    def rating_of(track_id)
      @db.read { |s| s.get_first_value("SELECT rating FROM tracks WHERE id = ?", [track_id]) }
    end

    # Aggregate (not per-play) history for the track-info modal: how many
    # times it's been played, total time actually played, and when last.
    def play_stats(track_id)
      rows = @db.read do |s|
        s.execute("SELECT started_at, ended_at FROM playback_history WHERE track_id = ?", [track_id])
      end
      return { count: 0, last_played_at: nil, total_played_ms: 0 } if rows.empty?
      total_ms = rows.sum { |r| (Time.parse(r["ended_at"]) - Time.parse(r["started_at"])) * 1000 }.round
      { count: rows.size, last_played_at: rows.map { |r| r["started_at"] }.max, total_played_ms: total_ms }
    end

    def set_errored(track_id)
      @db.write { |s| s.execute("UPDATE tracks SET errored = 1 WHERE id = ?", [track_id]) }
    end

    def find_track(id)
      row = @db.read { |s| s.execute("SELECT * FROM tracks WHERE id = ?", [id]).first }
      row && Track.from_row(row)
    end

    # Removing a folder from the library is a soft delete (same `missing`
    # flag the Scanner uses for vanished files), not a hard DELETE: tracks
    # and folders have no ON DELETE CASCADE beyond track_metadata, so a hard
    # delete would need manual bottom-up cleanup across playback_history too.
    # Soft delete also means a future rescan naturally restores the folder if
    # the files are still on disk -- consistent with "library" tracking what's
    # on disk, not permanent user curation. Returns the removed track ids so
    # the caller can cascade-remove them from the live playback queue (queue
    # entries are in-memory Track objects, untouched by this DB update).
    def remove_folder!(folder_id)
      rows = @db.read do |s|
        s.execute(<<~SQL, [folder_id])
          WITH RECURSIVE sub(id) AS (
            SELECT id FROM folders WHERE id = ?
            UNION ALL
            SELECT f.id FROM folders f JOIN sub ON f.parent_id = sub.id
          )
          SELECT 'folder' AS kind, id FROM sub
          UNION ALL
          SELECT 'track' AS kind, t.id FROM tracks t WHERE t.folder_id IN (SELECT id FROM sub)
        SQL
      end
      folder_ids = rows.select { |r| r["kind"] == "folder" }.map { |r| r["id"] }
      track_ids = rows.select { |r| r["kind"] == "track" }.map { |r| r["id"] }
      mark_missing(track_ids: track_ids, folder_ids: folder_ids)
      recompute_counts!
      track_ids
    end

    def mark_missing(track_ids:, folder_ids:)
      return if track_ids.empty? && folder_ids.empty?
      @db.write do |s|
        track_ids.each_slice(500) do |ids|
          s.execute("UPDATE tracks SET missing = 1 WHERE id IN (#{ids.join(',')})")
        end
        folder_ids.each_slice(500) do |ids|
          s.execute("UPDATE folders SET missing = 1 WHERE id IN (#{ids.join(',')})")
        end
      end
    end

    # Bottom-up recursive track_count recompute, done in Ruby (a correlated
    # recursive CTE per row is not reliably supported by SQLite).
    def recompute_counts!
      folders = @db.read { |s| s.execute("SELECT id, parent_id FROM folders") }
      direct = Hash.new(0)
      @db.read { |s| s.execute("SELECT folder_id, COUNT(*) AS c FROM tracks WHERE missing = 0 GROUP BY folder_id") }
         .each { |r| direct[r["folder_id"]] = r["c"] }
      children = Hash.new { |h, k| h[k] = [] }
      folders.each { |f| children[f["parent_id"]] << f["id"] }
      totals = {}
      compute = lambda do |id|
        totals[id] ||= direct[id] + children[id].sum { |c| compute.call(c) }
      end
      folders.each { |f| compute.call(f["id"]) }
      @db.write do |s|
        totals.each { |id, n| s.execute("UPDATE folders SET track_count = ? WHERE id = ?", [n, id]) }
      end
    end

    def folder_stats
      @db.read do |s|
        { folders: s.get_first_value("SELECT COUNT(*) FROM folders WHERE missing = 0"),
          tracks: s.get_first_value("SELECT COUNT(*) FROM tracks WHERE missing = 0") }
      end
    end

    # All top-level roots (regardless of visibility) — rescanned on startup.
    def root_paths
      @db.read do |s|
        s.execute("SELECT path FROM folders WHERE parent_id IS NULL").map { |r| r["path"] }
      end
    end

    # For the Scanner's diff pass: everything the DB knows under `root`.
    def db_paths_under(root)
      prefix = root.chomp("/") + "/"
      tracks = {}
      folders = {}
      @db.read do |s|
        s.execute(<<~SQL, [root, "#{prefix}%"]).each do |r|
          SELECT physical_path, file_mtime, file_size, GROUP_CONCAT(id) AS ids
          FROM tracks
          WHERE missing = 0 AND (physical_path = ? OR physical_path LIKE ?)
          GROUP BY physical_path
        SQL
          tracks[r["physical_path"]] = { mtime: r["file_mtime"], size: r["file_size"],
                                         ids: r["ids"].split(",").map(&:to_i) }
        end
        s.execute("SELECT id, path, mtime, size FROM folders WHERE missing = 0 AND (path = ? OR path LIKE ?)",
                  [root, "#{prefix}%"]).each do |r|
          folders[r["path"]] = { id: r["id"], mtime: r["mtime"], size: r["size"] }
        end
      end
      { tracks: tracks, folders: folders }
    end

    private

    def query_tracks(where_and_order)
      rows = @db.read { |s| s.execute("SELECT * FROM tracks WHERE #{where_and_order}") }
      rows.map { |row| Track.from_row(row) }
    end

    def visible_folders(where, params = [])
      @db.read do |s|
        s.execute("SELECT * FROM folders WHERE #{where} AND missing = 0 AND track_count > 0 ORDER BY name COLLATE NOCASE", params)
      end
    end
  end
end
