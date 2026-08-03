# Filtered Songs Pane Title

## Goal

Make the TracksPane title explain both the filtered result count and the
unfiltered total whenever the Songs pane has an active filter.

Example:

```text
All Songs · 79 of 382 (Filter: 'foo')
```

The behavior applies to every track-containing Songs view: folders, All Songs,
smart views, history, queue, and playlist-track views. The playlist index and
Focus Sounds views retain their existing title behavior because their rows are
not database-backed songs.

## Design

`TracksPane#title` remains the single source of title formatting. It already
has both values needed:

- `filtered_tracks.size`: rows matching the current filter;
- `@tracks.size`: rows loaded for the current view before filtering.

When `@filter.strip` is empty, title output remains unchanged:

```text
All Songs · 382
```

When the filter is effective, title output becomes:

```text
All Songs · 79 of 382 (Filter: 'foo')
```

The displayed filter uses the exact text entered by the user. Apostrophes in
the term are escaped so the single-quoted label remains readable. Existing
`max_width` truncation remains the final step, preserving current pane-layout
behavior on narrow terminals.

## Data flow

Filtering continues to invalidate the memoized filtered-track cache. The title
then reads the refreshed cache and the unchanged source-track array; no new
Library query or per-frame count query is introduced. Reloads and view changes
continue replacing `@tracks` before the title is rendered.

## Testing

Add TracksPane tests covering:

1. An active filter reports matching count, total count, and exact filter text.
2. A filter with no matches reports `0 of M` and the filter label.
3. Clearing the filter restores the existing compact title.
4. A filter containing an apostrophe renders a safe quoted label.
5. Existing title truncation still applies to the expanded title.

Run the focused TracksPane tests, RuboCop on changed Ruby files, and the full
test suite before completion.

