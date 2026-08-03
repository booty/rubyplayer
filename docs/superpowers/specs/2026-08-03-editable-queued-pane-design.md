# Editable Queued Sidebar

## Goal

Make the always-visible `Queued` sidebar an editable, focusable queue view.
Tab should cycle through Library, Tracks, and Queued whenever the sidebar is
actually rendered. When the terminal is too narrow, the sidebar remains hidden
and Tab keeps its existing two-pane behavior. The top-level Library item
`Playback Queue` remains available and keeps its current full-list behavior;
the sidebar is suppressed while that item is selected.

The sidebar displays upcoming queue items followed by three recent history
items. Only upcoming rows are selectable and editable. History rows remain
visible but are decorative, so queue mutations cannot target playback history.

## Design

### Shared queue-selection capability

Extract queue-specific selection behavior from `TracksPane` into a small shared
component/module used by both queue surfaces. It owns:

- the ordered upcoming `Track` snapshot;
- selected-item identity and queue index resolution;
- cursor movement, page movement, scroll following, and clamping;
- reload behavior that preserves the selected track when possible; and
- the selected upcoming track exposed to App-level queue commands.

The capability does not render rows. `TracksPane` keeps its existing filter and
full queue presentation. `QueuedPane` keeps its two-section upcoming/history
layout and uses the shared capability only for upcoming-row selection. This
keeps presentation differences explicit while centralizing queue invariants.

### Focus and layout

`App#active_pane` gains `:queued` as a valid focus value when
`queued_pane_cols(screen.cols)` is positive. Tab cycles in visual order:

```text
Library -> Tracks -> Queued -> Library
```

If the sidebar is hidden because of terminal width, preference, or the
top-level Playback Queue view, the cycle contains only Library and Tracks. If
the sidebar becomes hidden while focused (resize, toggle, or selecting the
top-level queue), App moves focus to Tracks so no input is stranded on an
invisible pane. The sidebar border receives the active style only when
`:queued` is focused.

### Input and mutations

Queued-pane-local navigation (`up`, `down`, page navigation) routes to the
shared queue-selection capability. Global queue actions use the active queue
selection regardless of whether it came from `TracksPane` in `:queue` mode or
`QueuedPane`:

- `x` removes the selected upcoming track by resolving its object identity
  against the live engine queue, preserving the existing current-track safety
  behavior;
- `enter`/play-now uses the selected queue track with the same engine command
  used by the top-level queue view;
- `q`, `n`, undo, redo, skip, and playback controls retain their existing global
  meanings; and
- actions that only make sense for library rows (folder expansion, ratings,
  playlist operations, sorting/grouping) remain unavailable in the sidebar.

After a queue mutation or playback event, both queue surfaces reload their
snapshots and clamp/preserve selection by track identity. The sidebar’s
previous-history snapshot continues to refresh independently and never enters
the editable selection domain.

### Rendering and hotkeys

`QueuedPane#render` accepts `active:` and highlights the selected upcoming row
with the active selection theme. Rows in the `Previously` section never receive
selection highlighting. Existing headers, duration totals, overflow rows, and
formatter behavior remain unchanged.

The hotkey footer is generated for the active pane. Queued uses the same
navigation and global queue labels as the other interactive panes, with no new
shortcut text added specifically for focus cycling.

## Data flow

1. `PlaybackEngine#upcoming_items` supplies the authoritative ordered queue
   snapshot to both panes.
2. The shared queue-selection capability publishes a selected `Track` and
   resolves its current index only when App performs a mutation.
3. App dispatches actions based on `active_pane`; queue mutations call the
   existing engine API, never mutate snapshots directly.
4. Queue/history events trigger the existing pane refresh path. Reload keeps
   the selected track when it survives; otherwise selection clamps to the
   nearest upcoming row.
5. Layout calculation determines whether Queued participates in focus cycling;
   rendering and focus use the same visibility predicate.

## Error handling

- A stale selected track (removed by playback or a concurrent event) is a
  no-op with the existing queue-selection status message.
- Empty upcoming queues show the existing `Queue empty` row and expose no
  selectable track; history remains visible.
- Hidden or too-narrow Queued panes cannot retain focus.
- Removing the currently playing head continues through
  `PlaybackEngine#remove_at`, preserving decoder-thread safety.

## Testing

Add focused regression coverage for:

1. Shared queue selection preserves identity across reloads and clamps after
   removal/advance.
2. Queued-pane arrows/page keys move only through upcoming rows; history rows
   are never selectable.
3. Queued-pane rendering highlights the selected upcoming row only when active.
4. Tab cycles Library → Tracks → Queued on a wide screen and skips Queued when
   hidden, including focus recovery after resize/toggle/top-level queue view.
5. Sidebar `x` removes the selected upcoming track, while history selection or
   an empty queue is a safe no-op.
6. Sidebar play-now and queue actions match top-level Playback Queue behavior.
7. Existing top-level queue tests, rendering thresholds, and hotkey output stay
   green.

Run focused UI tests, RuboCop on changed Ruby files, and the full suite before
completion.
