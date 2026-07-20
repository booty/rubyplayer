# Rich Metadata Ingestion — Design

Date: 2026-07-20
Status: approved in conversation (user AFK; auto-approved by request).

## Summary

Ingest the full tag set ffprobe exposes (ID3v1/v2, MP4 atoms, FLAC/Vorbis
comments — ffprobe normalizes all of them into one `tags` dict, so no
per-format parsing is needed). Two new promoted columns on `tracks` for
sort/group/filter hot paths; everything else goes to the existing
`track_metadata` KV sidecar for on-demand reads. Filename/folder fallbacks
for missing album/title are baked at ingest time.

Optimization priority (user-stated): frequent operations (sort, group,
filter) over rare ones (initial scan).

## Decisions

- **Promoted columns (schema v3):** `album_artist TEXT`, `year INTEGER`.
  Only these — every view query is `SELECT *` and hydrates a `Track` struct
  per row; the hot row stays narrow. Genre/disc/track-total stay in KV and
  can be promoted later with a cheap schema bump.
- **KV sidecar for the rest:** all remaining normalized tags (genre, disc,
  comment, raw date, encoder, isrc, label, lyrics when present, …) are
  stored in `track_metadata` at scan. Loaded only on demand (track-info
  modal; future lyrics feature). Never loaded during list rendering.
- **Lyrics:** KV, not a column. Kilobyte TEXT in `tracks` would push rows to
  SQLite overflow pages and every `SELECT *` view query would drag those
  pages through the cache to benefit a modal nobody opened.
- **Deliberately ignored:** embedded pictures (extracted on demand by
  `Artwork`, never stored in DB), `SYLT` synced lyrics, `POPM` file ratings
  (would clobber user ratings on rescan).
- **Multi-value tags:** stored as the joined string ffprobe returns. No
  normalization tables.
- **Year:** first plausible 4-digit number (1000–2999) found in the
  `date`/`year` family of tags, as INTEGER. Raw date string still lands in
  KV under its own key.
- **Normalization at one choke point:** tag keys downcased, values
  `String#scrub`-ed (mislabeled ID3 encodings otherwise plant invalid UTF-8
  that crashes Ruby string ops far from the scan), values truncated to a
  configurable byte cap.
- **Fallbacks at ingest, not render:** SQL `ORDER BY` in Library view
  queries and Ruby-side pane sorts must see the same values, and the
  live filter must match them — only possible if the fallback IS the stored
  value. Staleness self-heals: folder rename = path change = rescan.
  - Album fallback: archive entry → archive basename sans extension;
    multitrack container (nsf/gbs) → container filename sans extension;
    plain file → parent folder name.
  - Approximation vs placeholder: derived-from-path values get baked;
    literal placeholders ("Unknown Album") are never stored — absent stays
    NULL and presentation decides.
  - No filename cleanup heuristics ("01 - Foo" stripping) in this version.
- **Grouping correctness:** album grouping key becomes
  `[album_artist-or-empty, album]` so two different "Greatest Hits" albums
  no longer merge. An explicit `album_artist` tag also takes precedence
  over the existing majority-artist tally for the grouped formatter's
  artist-suppression rule.
- **Sorting:** new tracks-pane sort `sort_year` on key `e` (free), sorting
  by `[year-or-0, album, track_number]`. Existing sorts untouched.
- **Info modal:** shows Album artist and Year rows when present, plus KV
  metadata pairs (bounded count) fetched on open.
- **Retro backends (gme/openmpt):** unchanged; new columns stay NULL for
  them apart from the album fallback, which applies uniformly in the
  extractor.
- **Schema v3 = DB rebuild + rescan** per standing pre-1.0 policy (backup
  taken; playlists/ratings/history reset — accepted; ship before heavy
  playlist investment accumulates).

## Out of scope

- Lyrics display UI (future version reads the KV rows this feature writes).
- Genre/disc promotion, multi-artist normalization, ReplayGain application,
  filename cleanup heuristics, tag writing/editing.
