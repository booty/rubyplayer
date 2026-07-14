# Purge Missing Tracks Design

## Goal

Let users permanently remove filtered, visible entries from Missing view with `Ctrl+X`.

## Interaction

- `Ctrl+X` maps to `purge_visible_missing` globally.
- Command is enabled only while Library selection is Missing.
- Target set is Tracks pane's currently filtered, visible `Track` values.
- Empty target or wrong view produces status feedback without mutation.
- Non-empty target opens confirmation: `Permanently remove N missing tracks and their history?`
- Enter or `y` confirms; Escape or `n` cancels.

## Data Semantics

`Library#purge_missing_tracks!(ids)` deletes only rows satisfying `missing = 1`.
Within one write transaction it deletes matching playback history, track metadata,
then tracks. It recomputes folder counts and returns IDs actually deleted.

Hard-deleted missing files remain absent because scanner cannot see them. If a file
later returns on disk, scanner discovers it as a new track.

## Coordination

`UI::App` captures target IDs before confirmation, calls Library purge, removes
matching stale queue entries through `PlaybackEngine#remove_track_ids`, rebuilds
panes, and reports deleted count. Existing folder-removal confirmation remains
unchanged.

## Testing

- Keymap maps `ctrl_x` distinctly.
- Tracks pane exposes only filtered visible tracks.
- Library purge deletes missing rows and history while rejecting healthy IDs.
- App checks view, confirms/cancels, purges captured visible IDs, and refreshes.
- Full suite remains green.
