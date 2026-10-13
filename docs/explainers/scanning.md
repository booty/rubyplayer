# Library scan sequence

Status: **current**, reviewed 2026-10-10 against implementation.

A scan has two sequential phases per root: filesystem reconciliation, then
metadata extraction. The UI remains responsive while a background orchestration
thread runs both phases. See the [component map](components.md) for shared services.

```mermaid
sequenceDiagram
    participant App as UI::App (main thread)
    participant Scan as Scan orchestration thread
    participant Scanner
    participant Library as Library / SQLite
    participant Pool as ExtractorPool
    participant Worker as Extractor workers
    participant Cache as ArchiveCache
    participant Backend as Registry / backends
    participant Bus as EventBus

    App->>Scan: scan_paths(remembered roots + argv)
    loop For each root, sequentially
        Scan->>Scanner: reconcile(root)
        Scanner->>Library: Load known paths and upsert directory folders
        Note over Scanner: Walk and stat supported files, compare mtime and size
        Note over Scanner: Archives are diffed using archive folder rows
        Scanner->>Library: Mark unseen tracks and folders missing
        Scanner-->>Scan: WorkItems for new or changed files and archives

        Scan->>Pool: process(work_items)
        Pool->>Worker: Queue WorkItems and start bounded worker pool
        loop Each worker processes assigned items
            opt WorkItem is an archive
                Worker->>Cache: Materialize archive and nested archives
                Cache-->>Worker: Extracted files
                Worker->>Library: Upsert archive and virtual directory folders
            end
            Worker->>Backend: Select backend and extract file metadata
            Backend-->>Worker: Metadata and subtune information
            alt File or entry decoded successfully
                Worker->>Library: Upsert tracks, metadata, and multitrack folders
                Note over Worker,Library: Upserts restore missing rows for entries still present
            else Extraction fails
                Worker->>Library: Upsert errored track preserving file identity
            end
            Worker->>Bus: Publish scan_progress
        end
        Worker-->>Pool: All workers finish and join
        Pool->>Library: recompute_counts!
        Pool->>Bus: Publish scan_complete(processed, errored)
        Pool-->>Scan: Result counts
    end
    Bus-->>App: Self-pipe wakes IO.select
    App->>Bus: drain
    Note over App: Throttle progress refreshes to 250 ms; always refresh on scan_complete
```

## Why phase order matters

Scanner reads filesystem metadata and compares it with database state; it never
opens music files for metadata or decoding. Unchanged supported files generate
no extraction work. Workers do the expensive backend calls after reconciliation
has returned its complete list of `WorkItem`s.

For an **unchanged archive**, Scanner marks its known descendants seen. For a
**changed archive**, it leaves the old inner rows unseen, so reconciliation marks
them missing. Extraction then upserts the entries that still exist, clearing
their missing flags. Removed entries stay missing. Running these phases in
parallel for the same root would break that restoration order.

Archive track identity keeps the on-disk container in `physical_path` and the
inner path, including nested chains, in `archive_entry`. Extracted cache paths
are temporary decoding inputs, not replacements for persistent track identity.
Multi-subtune files become virtual folders containing individual track rows.

Missing scan rows are soft-deleted with `missing = 1`. Extraction failures retain
errored rows so they remain visible in Failed to Scan. A scan with no WorkItems
still recomputes folder counts and publishes completion: reconciliation may have
changed missing flags without discovering anything to decode.

## Events and counts

Progress is published per top-level WorkItem with completed and total counts,
and completion follows worker joins and count recomputation. `processed` counts WorkItems, not resulting tracks:
one archive or multi-subtune file can yield many tracks. `errored` counts failed
WorkItems; individual entry failures can be isolated inside an otherwise
successfully processed archive. App progressively reloads panes at most once
every 250 ms so extracted metadata appears during a large scan without making
each completed file trigger a full pane rebuild. Completion always performs a
final refresh after folder counts are recomputed. The UI never decodes files.

The final UI steps in the diagram can occur throughout the scan as events arrive.
Completion is emitted per root because App invokes `process` separately for
each root.

## Source entry points

| Step | Source and methods |
|---|---|
| Background orchestration and refresh | [UI::App](../../lib/rubyplayer/ui/app.rb): `scan_paths`, `handle_events`, `refresh_panes` |
| Filesystem comparison and missing flags | [Scanner](../../lib/rubyplayer/scanner.rb): `reconcile`, `walk`, `diff_file`, `diff_archive` |
| Worker lifecycle and metadata persistence | [ExtractorPool](../../lib/rubyplayer/extractor_pool.rb): `process`, `extract`, `extract_tracks`, `extract_archive`, `walk_extracted` |
| Archive materialization | [ArchiveCache](../../lib/rubyplayer/archive_cache.rb) |
| Format classification and backend selection | [Registry](../../lib/rubyplayer/backends/registry.rb) |
| Upserts, missing flags, and counts | [Library](../../lib/rubyplayer/library.rb), [Database](../../lib/rubyplayer/database.rb) |
| Progress and completion notifications | [EventBus](../../lib/rubyplayer/event_bus.rb) |

[Component map](components.md) · [Playback sequence](playback.md) · [Project README](../../README.md#architecture)
