# All Songs Library Root Design

## Goal

Group every real and virtual library folder beneath a synthetic top-level
`All Songs` row. Selecting `All Songs` shows every present track. Selecting a
folder preserves existing behavior.

## Library Pane Structure

`LibraryPane` keeps existing fixed rows in their current order:

1. Playback Queue
2. History
3. Favorite Tracks
4. Focus
5. Recently Added
6. Unrated
7. Missing
8. Failed to Scan
9. Most Played

It then adds one synthetic row with kind `:all` and label `All Songs` at depth
zero. Current library roots follow at depth one. Their descendants retain their
existing relative nesting beneath each root.

`All Songs` starts expanded for every new `LibraryPane` instance. Existing
left/right expand and collapse actions toggle it. Collapsing it hides every
folder row without changing database state. Re-expanding it restores the same
folder tree expansion state held by `LibraryPane`.

Folder breadcrumbs remain folder-only paths such as `fixtures / archive`;
`All Songs` is a navigation group, not part of stored folder identity or path.
Its own breadcrumb and tracks-pane title are `All Songs`.

## Track Selection and Queries

`Library` gains an `all_tracks` query returning every track where `missing = 0`.
It uses deterministic physical-path and subtune ordering, matching folder-view
ordering. Missing tracks remain available only through views that explicitly
include them, especially `Missing` and diagnostic `Failed to Scan` behavior.

`TracksPane` recognizes `:all` as a normal database-backed track view. Selecting
`All Songs` loads `Library#all_tracks`, renders title `All Songs · N`, and keeps
existing filtering, grouping, sorting, selection, and scrolling behavior.

When Library pane is active, play and queue actions on `All Songs` operate on
all present tracks. When Tracks pane is active, they continue operating on only
selected track. Remove-library-item remains restricted to `:folder`, so
`All Songs` cannot be removed.

## Data Flow

1. `LibraryPane#rebuild!` emits fixed rows, synthetic `:all` row, then visible
   roots and descendants when `All Songs` is expanded.
2. Selection changes continue through `App#show_selected_tracks` into
   `TracksPane#show`.
3. `TracksPane#load_tracks` calls `Library#all_tracks` for `:all` mode.
4. Library-pane queue actions use the same query through `App#selected_tracks`.
5. Scan and playback refreshes rebuild Library pane and reload current Tracks
   pane mode, preserving existing refresh behavior.

## Error Handling and Compatibility

No schema, configuration, scanner, or persisted-data changes are required.
An empty library still shows selectable `All Songs`; Tracks pane shows its
existing empty-view message. Folder visibility rules remain unchanged: roots
with no present tracks stay hidden.

## Testing

Tests will be written before production changes and will cover:

- fixed-row order followed by `All Songs` and depth-one roots;
- default expanded state;
- collapsing and re-expanding `All Songs`;
- preservation of nested folder expansion state;
- `All Songs` breadcrumb and rendered label;
- `Library#all_tracks` returning present tracks while excluding missing tracks;
- Tracks pane title and content for `:all` mode;
- App selection loading all present tracks;
- Library-pane queue action enqueuing all present tracks;
- existing folder navigation, selection, removal guards, and full test suite.
