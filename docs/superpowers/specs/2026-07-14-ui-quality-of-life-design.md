# UI Quality-of-Life Design

## Goal

Improve discoverability, navigation speed, playback feedback, and small-terminal usability without replacing rubyplayer's pane architecture or keyboard-first interaction model.

## Scope

Deliver three independently testable milestones:

1. Playback feedback and contextual guidance
2. Navigation, filtering, breadcrumbs, and responsive layout
3. Database-backed smart library views

Existing themes, configurable keymap, queue semantics, and normal two-pane layout remain compatible.

## Architecture

Extend existing owners rather than introducing a global UI store:

- `PlaybackEngine#state` reports normal playback, active Focus sound, and next queued track.
- `LibraryPane` and `TracksPane` own display mode, remembered cursor/scroll state, filtering, breadcrumbs, and scrollbar calculations.
- `UI::App` remains interaction coordinator: input modes, disabled-action messages, and wide/narrow layout choice.
- `Library` owns smart-view SQL queries.

Pane actions return structured outcomes when an action is intentionally unavailable. `App` translates those outcomes into status-line feedback, keeping panes independent from status rendering.

## Milestone 1: Playback Feedback

### Focus-aware state

Engine state adds `focus_sound` and `next_track`:

- During normal playback, `track` is current queue head and `next_track` is following queue item.
- During Focus playback, `focus_sound` is active recipe, `track` is nil, and `next_track` is preserved queue head.
- When stopped, `track` and `focus_sound` are nil; `next_track` remains queue head when one exists.

### Playback line

Render modes:

- Normal: `▶ Title — Artist  1:42/3:18  Next: Next Title`
- Focus: `▶ Focus — Beach Rain  ∞  Queue paused · Next: Queued Title`
- Stopped with queue: `Ⅱ stopped  Next: Queued Title`
- Stopped without queue: `Ⅱ stopped`

EQ bars remain right-aligned. Text truncates before bars without negative widths on narrow terminals.

### Empty states

Tracks pane renders one muted instructional row when empty:

- Queue: `Queue empty — press N to add selected tracks`
- History: `No playback history yet`
- Favorites: `No favorites yet — press 1–6 while a track plays`
- Folder/smart view: `No tracks in this view`
- Filtered result: `No matches — press / to edit filter`

### Disabled-action feedback

Actions that currently disappear silently return a reason:

- Queue grouping/sorting: `Queue order cannot be sorted or grouped`
- Focus grouping/sorting: `Focus sounds cannot be sorted or grouped`
- Track info without selected track: `Select a track to view info`
- Rating without normal current track: `Play a library track before rating`

Existing Focus queue rejection remains unchanged.

## Milestone 2: Navigation and Layout

### Quick filter

Default key `/` opens filter input in status row.

- Typing updates Tracks pane live.
- Matching is case-insensitive across title, artist, album, composer, and displayed path/breadcrumb text where available.
- Enter accepts current filter and returns to navigation.
- Escape cancels edits and restores filter active before `/` was pressed.
- Backspace edits; submitting empty text clears filter.
- Filter remains scoped to current view and is remembered per view.
- Queue filtering is supported; removal resolves selected `Track` identity against underlying queue rather than using filtered row position.
- Focus filtering matches recipe titles.

### Breadcrumb pane titles

Replace static right-pane title with mode-aware title and visible count:

- `Tracks · Music / Chiptunes / Game · 42`
- `Playback Queue · 12`
- `Focus · 6`
- `Recently Added · 25`

Long breadcrumbs truncate from left, preserving current folder/view name and count.

### Remembered view position

Tracks pane stores selected stable item and scroll offset per mode. Returning to Queue, Focus, Favorites, History, smart views, or a folder restores prior context. If item disappeared, clamp to nearest valid row.

Library pane keeps existing selection behavior.

### Scrollbar

When rows exceed viewport, draw a one-column scrollbar at pane's right interior edge:

- `█` marks proportional thumb.
- `│` marks remaining track.
- No scrollbar when all rows fit.
- Content width shrinks by one only when scrollbar exists.

### Responsive single-pane mode

When terminal width is below 72 columns, render only active pane at full width. Tab switches panes. Bottom playback/status/hotkey lines remain. At 72 columns or wider, preserve configurable two-pane split.

## Milestone 3: Smart Views

Add fixed top-level Library rows after Focus:

- Recently Added
- Unrated
- Missing
- Failed to Scan
- Most Played

Queries:

- Recently Added: `missing = 0`, newest non-null `added_at` first, then title.
- Unrated: `missing = 0 AND rating IS NULL`, title order.
- Missing: `missing = 1`, physical path then title.
- Failed to Scan: `errored = 1`, physical path then title; includes missing failures.
- Most Played: `missing = 0`, inner join playback history, order by play count descending, total played duration descending, then title.

Smart views return normal `Track` values and therefore support playback, queueing, sorting, filtering, info, ratings, breadcrumbs, remembered selection, and scrollbar behavior.

## Error Handling

- Filtering never mutates library or queue data.
- Missing selected items clamp safely after reload.
- Smart-view query failures follow existing database error handling; no partial cached result is retained.
- Narrow terminals with insufficient rows continue clipping existing bottom/modal content safely.
- Disabled actions give status feedback but never raise.

## Testing

### Engine and playback line

- Focus and normal `state` combinations
- next-track selection while playing, focused, and stopped
- playback-line text/truncation with EQ bars

### Panes and app flow

- contextual empty rows
- disabled-action outcomes and status messages
- live filter accept/cancel/clear behavior
- filtering fields and Focus titles
- queue removal through filtered rows
- per-view selection restoration
- breadcrumb truncation and counts
- scrollbar thumb bounds and visibility
- 71-column single-pane and 72-column two-pane rendering

### Library and smart views

- each query's inclusion/exclusion rules
- deterministic ordering
- history aggregation for Most Played
- LibraryPane fixed-row ordering and selection

Run full suite after each milestone.

## Documentation

Update README controls for `/` filtering, narrow layout behavior, dynamic pane titles, and smart views. Keep configuration documentation unchanged unless a new threshold setting is introduced; initial 72-column threshold remains an internal constant.
