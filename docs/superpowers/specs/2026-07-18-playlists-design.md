# User-Defined Playlists — Design

Date: 2026-07-18
Source request: `docs/playlists-planning.md`

## Summary

User-curated playlists stored in the library database, surfaced as an
expandable "Playlists" node in the Library pane sidebar. Tracks are added
from any track view via a hotkey-driven modal (which is also how playlists
are created). A playlist's tracks render as a flat, position-ordered list
with reorder/remove hotkeys; playlists themselves support duplicate,
rename, and delete.

Decisions made during brainstorming:

- **Creation happens in the add-to-playlist modal** (filter text doubles as
  the new playlist's name). No separate "new playlist" hotkey; a playlist is
  always born with at least one track.
- **Navigation is tree children**: the Playlists sidebar node expands like a
  folder; each playlist is a child row. The parent node also gets a
  right-pane playlist list (sortable, jumps into a playlist on Enter).
- **Missing tracks are hidden, entries kept**: a playlist entry whose track
  is soft-deleted (`missing = 1`) disappears from view but keeps its
  position, reappearing when a rescan restores the file. Hard purge
  (`ctrl_x`) removes the entry permanently.
- **Rename is included** alongside the doc's duplicate/delete.
- **Storage is DB tables** (option A), not m3u files: track-id references
  make archive entries and subtunes work with zero extra syntax, and all
  existing `Library` query patterns apply. Trade-off: playlists are lost on
  future schema-version rebuilds, same as ratings — accepted pre-1.0, and
  DB backups exist.

## 1. Data layer

Schema version 1 → 2 (rebuild-from-scratch policy per CLAUDE.md).

```sql
CREATE TABLE playlists (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE COLLATE NOCASE,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL      -- bumped on any content/name change; recency sort key
);

CREATE TABLE playlist_tracks (
  playlist_id INTEGER NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  track_id INTEGER NOT NULL REFERENCES tracks(id),
  position INTEGER NOT NULL,
  PRIMARY KEY (playlist_id, position)
);
```

`PRIMARY KEY (playlist_id, position)` makes position integrity a database
constraint: a buggy renumber fails loudly instead of silently corrupting
order. Positions are kept contiguous (0..n-1) — every move/remove renumbers
inside a single write transaction.

### New `Library` methods

Same style as existing query methods (direct queries, no caching, so
scanner/rating changes appear on next pane reload):

| Method | Behavior |
|--------|----------|
| `playlists(sort:)` | All playlists; `:recency` (default, `updated_at DESC`) or `:alpha` (`name COLLATE NOCASE`). Includes visible track count. |
| `create_playlist(name)` | Insert; returns id. Name validated non-blank; `UNIQUE COLLATE NOCASE` is the backstop for duplicates. |
| `rename_playlist(id, name)` | Update name, bump `updated_at`. |
| `duplicate_playlist(id, name)` | Copy row + all entries (including hidden-missing ones) under the new name. |
| `delete_playlist(id)` | Hard DELETE (cascade removes entries). Playlists are user curation, not disk state — the library's soft-delete philosophy does not apply. |
| `playlist_tracks(id)` | Entries joined on `tracks.missing = 0`, position order. Hidden entries keep their stored positions. |
| `add_to_playlist(id, track_id)` | Append at max(position)+1. Duplicates allowed; the UI confirms first. Bumps `updated_at`. |
| `move_playlist_entry(id, visible_index, direction)` | Swap with visible neighbor; renumber contiguously in one transaction. |
| `remove_playlist_entry(id, visible_index)` | Delete entry, renumber. |
| `playlist_contains?(id, track_id)` | Duplicate check for the modal. |

**Visible-index translation:** UI operations address the row the user sees.
Because missing entries are hidden, `Library` maps visible index → real
position **inside the write transaction** — the same stale-target
discipline as `purge_missing_tracks!` (state can shift while a modal is
open).

`purge_missing_tracks!` additionally executes
`DELETE FROM playlist_tracks WHERE track_id IN (...)` so hard-purged tracks
leave playlists for good.

## 2. Sidebar and navigation

New dynamic row kinds in `LibraryPane`: `:playlists` (parent) and
`:playlist` (child). Placed directly **above** `:all` in the sidebar — the
folder tree already owns the vertical space beneath `:all`, so this keeps
tree rendering untouched while satisfying "top-level item near All Tracks".
`Views::ALL` stays fixed-view-only; playlist rows are built dynamically in
`rebuild!`, like folder rows.

- Parent expands/collapses with the existing `right`/`left` bindings.
  Children listed in recency order.
- **Parent selected** → right pane lists playlists: name, visible track
  count, relative last-used time. Sortable alpha/recency via the existing
  tracks-pane sort keys; recency is default. `enter` on a playlist row
  jumps selection to that playlist's sidebar child row (expanding the
  parent if collapsed).
- **Child selected** → right pane shows that playlist's tracks, flat,
  position order, **never sorted or grouped** — the same load-bearing rule
  as the queue view: row index == visible playlist position, and
  move/remove depend on it. Sort/group hotkeys no-op here.
- Playing or enqueueing works exactly like any other track view (existing
  `selected_tracks` path). Enqueueing the playlist row enqueues its visible
  tracks in position order.

## 3. Add-to-playlist modal

Global hotkey **`l`** (currently free) fires `add_to_playlist` on the
highlighted track in any track view. Modal renders last in `App#render`
(standard last-writer-wins layering).

Contents:

- Top section: up to 3 most recently updated playlists as direct-pick rows
  (fewer if fewer exist).
- Below: full alphabetical playlist list with find-as-you-type filter
  (same live-filter interaction as `filter_tracks`).
- Last row, always visible: **"New playlist: <typed text>"** — the filter
  text doubles as the name. Enter creates the playlist and adds the track
  in one step. Disabled while the filter is empty.
- Zero playlists exist → modal opens directly in name-entry state.
- Duplicate handling: picking a playlist that already contains the track
  swaps the modal body to "Already in <name>. Add again? (y/n)". `y`
  appends the duplicate entry; `n`/`esc` cancels back to the list.
- `esc` closes. Status line confirms: "Added to <name>".

## 4. Playlist operations and hotkeys

While a playlist's tracks are in the right pane (tracks pane focused):

| Key | Action | Behavior |
|-----|--------|----------|
| `ctrl_up` / `ctrl_down` | `move_entry_up` / `move_entry_down` | Swap with neighbor; selection follows the moved track. Requires two new `KeyDecoder` entries (`[1;5A`, `[1;5B` — same xterm modifier scheme as the existing shift-arrows). |
| `x` | remove entry | Reuses the existing global `x` binding (today only meaningful in the queue view); extends to playlist views. No confirmation — single-entry removal is cheap to redo. |

While the Playlists parent or a playlist child is selected in the Library
pane:

| Key | Action | Behavior |
|-----|--------|----------|
| `c` (free) | duplicate playlist | Name-prompt modal, prefilled "<name> copy". |
| `r` (free) | rename playlist | Same name-prompt modal. |
| `x` | delete playlist | Routes through the existing library-pane `remove_library_item` binding to a confirm modal: "Delete playlist <name>? (y/n)". |

The name-prompt modal is one shared component used by create (inside the
add modal), duplicate, and rename. It validates non-blank + unique and
shows an inline error without closing.

All mutations bump `updated_at`, so recency ordering shifts and the sidebar
rebuilds through the existing `rebuild!` path.

## 5. Edge cases and error handling

- **Stale visible indexes:** move/remove re-resolve visible index → real
  position inside the write transaction (missing-set can change while UI
  state is held).
- **Playing a playlist** enqueues only visible (non-missing) tracks.
- **Duplicate names:** modal validates first; `UNIQUE COLLATE NOCASE`
  catches races. Violation surfaces as the inline "name taken" error.
- **Track hard-purged while the add modal is open:** the insert fails on
  the FK; caught and reported on the status line, modal closes.
- **Empty playlist** (all entries removed): remains listed with count 0;
  deleting it is the user's call.

## 6. Testing

TDD throughout (failing test first, per CLAUDE.md).

- `Library` layer: playlist CRUD, append/move/remove renumbering,
  visible-index translation with missing tracks, duplicate-copy fidelity,
  purge cascade, `COLLATE NOCASE` uniqueness. Plain DB tests with fixture
  tracks.
- UI: sidebar row construction (parent/child, expansion, recency order),
  playlist-list right pane, add modal (recent-3, filter, create-row,
  duplicate confirm), reorder/remove key handling, never-sorted rule.
  `Screen.new(out: StringIO)` render assertions + synthesized key events,
  following existing `app_test.rb` patterns (test methods above `private`).
- `KeyDecoder`: ctrl-arrow escape sequences.
- Regression comments on anything position-index-sensitive (the queue-view
  lesson: row index == position is load-bearing).

## Out of scope

- m3u import/export.
- Playlist artwork.
- Nested playlists / folders of playlists.
- Multi-select add.
