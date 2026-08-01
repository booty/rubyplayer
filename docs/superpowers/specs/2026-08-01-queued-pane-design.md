# Queued Pane Design

Status: current — 2026-08-01

## Goal

Add a read-only `Queued` pane at the far right of the normal library layout. It
summarizes upcoming playback and the three most recent playback-history events
without replacing or changing the interactive top-level `Playback Queue` view.

The pane is enabled by default, can be toggled with `B`, persists that choice,
and automatically disappears when the terminal is too narrow. Selecting the
top-level `Playback Queue` item also suppresses it because showing the same queue
twice provides no value.

## Non-goals

- The Queued pane does not receive focus, selection, scrolling, filtering,
  sorting, grouping, or queue-mutation actions.
- The existing `Playback Queue` Library item, Tracks pane queue rendering, and
  removal/reordering semantics do not change.
- Playback-history schema and recording thresholds do not change.
- The current track is not shown as upcoming.

## Components

### `UI::QueuedPane`

Add a dedicated read-only component. It receives callable sources for upcoming
tracks and recent history plus UI configuration. `reload!` snapshots both
sources; `render` consumes only those snapshots.

This boundary keeps SQL and engine locking out of frame rendering. It also
prevents the overview from acquiring `TracksPane` state that has no meaning for
it, such as selection, filter, scroll, sort, grouping, or queue indexes.

The history snapshot contains at most the three newest playback events in
newest-first order. Multiple plays of the same track remain separate rows.

### Shared track-row rendering

Extract the reusable parts of an individual track row from `TracksPane` into a
small UI helper:

- turn a `TrackFormatter` result into the existing segment-backed row shape;
- clip and draw styled segments against pane width;
- resolve semantic theme colors;
- preserve selected and unselected styling behavior.

Both `TracksPane` and `QueuedPane` use this helper. `TracksPane` retains all
interactive behavior and continues to expose its existing row hashes, so the
extraction does not disturb queue-position identity or current tests.

Extract the width-aware `--- Section ---` line construction as a shared helper
as well. `TracksPane` uses it for grouped album headers; `QueuedPane` uses it for
Upcoming and Previously.

Add a compact queued-row formatter setting whose default renders title,
duration, and artist. It uses the existing `TrackFormatter` contract and is
customizable as `config.ui.format_track_queued`.

### `PlaybackEngine#upcoming_items`

Expose an atomic, mutex-protected upcoming snapshot:

- while normal playback is active, omit queue index zero because it is the
  current track;
- while paused, normal playback remains active, so still omit the current
  track;
- while stopped or Focus playback is active, return the full queue because its
  head is the next normal track.

Computing this inside the engine avoids a race between separate `state` and
`queue_items` reads in the UI.

## Content and allocation

The Queued pane has two sections:

```text
--- Upcoming (4/40:40) ---
Song 3 10:10 Deerhoof
Song 4 10:10 Deerhoof
Song 5 10:10 Deerhoof
Song 6 10:10 Deerhoof

--- Previously ----------
Song 1 10:10 Deerhoof
Song 2 10:10 Deerhoof
Song 3 10:10 Deerhoof
```

The Upcoming count and duration describe the complete upcoming snapshot, not
only visible rows. Known durations are summed with `DurationFormatter`. If one
or more durations are unknown, append ` + ??` to the known sum, for example
`123:45 + ??` or `0:00 + ??`.

The Previously section is allocated first and anchored below Upcoming. On a
normally sized pane, its header and all three available history events always
remain visible. Upcoming consumes the rows left between its header and the
previous block.

When all upcoming tracks fit, show all of them. When they do not fit, reserve
the final upcoming row for `+ N more`, where `N` counts undisplayed upcoming
tracks. Empty sections show `Queue empty` and `No playback history yet`.

Extremely short terminals degrade by preserving recent-history rows before
upcoming rows. This is the only case in which the full two-section shape may
not fit.

## Layout and visibility

When every optional pane fits, layout order is:

```text
Library | Tracks | Now Playing artwork | Queued
```

Add these settings:

- `config.ui.queued_pane = true`
- `config.ui.queued_pane_width = 36`
- `config.ui.format_track_queued`, a callable defaulting to title, duration,
  and artist segments

The Queued width includes its border. It is visible only when all these
conditions hold:

1. the saved preference is enabled;
2. the selected Library row is not the top-level Playback Queue;
3. reserving its configured width leaves at least 72 columns for the existing
   Library + Tracks layout.

`queued_pane_width` must be a positive integer.

With the default width, the effective minimum terminal width is 108 columns.
Below that width, Queued disappears automatically without changing the saved
preference.

Queued has priority over the optional dedicated artwork pane because Queued is
enabled by default and artwork already degrades when space is insufficient.
After reserving Queued, dedicated artwork appears only if its width still
leaves at least 72 columns for Library + Tracks. Thus both default-width side
panes fit at 138 columns. The artwork inset and corner modes continue using
their existing layout rules inside the remaining main layout.

Terminals at or below 71 columns retain the current single-active-pane layout;
Queued and dedicated artwork are absent.

Queued never becomes `@active_pane`. Tab continues to alternate only between
Library and Tracks. Hotkey scope and help remain based on those two panes.

## Toggle and configuration persistence

Add collision-free global key `B`/`b` as `toggle_queued_pane`. Key matching
remains case-insensitive. The hotkey line and help label it as the queue-bar
toggle.

Toggling calls a per-setting managed-block writer, parallel to theme and art
mode persistence. Add `queued_pane` to `ConfigStore::MANAGED_SETTINGS` and a
`persist_queued_pane` entry point. Automatic hiding never writes configuration.

If the user enables the preference while the terminal is too narrow, persist
the enabled state and show a status message explaining that the pane will
appear at a wider terminal size. A persistence or validation failure uses the
existing config-error modal; runtime remains usable.

External config reload immediately updates queued visibility, width, formatter,
and keymap.

The config validator currently compares boolean settings by concrete class,
which rejects `false` when a default is `true`. Correct boolean validation so
either `true` or `false` is accepted for boolean defaults. This targeted fix is
required for `ui.queued_pane` and also makes the existing `ui.art_accent = false`
setting valid.

## Refresh flow and performance

Initialize and load QueuedPane alongside the existing panes. Refresh its
snapshots on events that can change upcoming membership or recent history:

- `queue_changed`;
- `track_started`;
- `track_ended`;
- relevant `playback_state` changes, including normal-to-Focus transitions.

History recording happens before `track_ended`, so the refreshed history sees
the completed event. Queue snapshots come through the new engine method.

Rendering does not call the engine, query SQLite, or rebuild formatter segments
unless the pane snapshot or configuration changed. Existing dirty-flag behavior
remains authoritative: no events or input means no idle repaint and near-zero
idle CPU use.

## Error and edge behavior

- Missing track durations affect only the total suffix; individual rows keep
  existing formatter behavior.
- Fewer than three history events display as many as exist.
- Repeated history events and a track appearing in both sections are valid.
- Queue changes while Queued is auto-hidden still refresh its snapshot, so it
  is current immediately after a resize makes it visible.
- Selecting or leaving the top-level Playback Queue causes a relayout but does
  not mutate queued preference.
- Invalid queued width or formatter configuration follows existing atomic
  config-reload behavior: keep active configuration and show the error modal.

## Testing

Follow TDD with focused failures before implementation.

### QueuedPane tests

- headers contain complete upcoming count and total;
- all-known, mixed-known/unknown, and all-unknown totals format correctly;
- compact formatted rows preserve segment styling and clip to width;
- three newest history events render newest first, including duplicates;
- empty-state messages render;
- overflow reserves the last upcoming row and reports the exact hidden count;
- previous rows take allocation priority on short panes.

### PlaybackEngine tests

- playing and paused snapshots exclude the current queue head;
- stopped and Focus snapshots include the queue head;
- returned items are a stable snapshot.

### App layout and event tests

- Queued is visible by default at 108 columns and hidden below 108;
- top-level Playback Queue selection suppresses Queued;
- Queued is rightmost when dedicated artwork also fits;
- Queued remains while dedicated artwork degrades at intermediate widths;
- inset and corner artwork use the remaining main layout correctly;
- Tab never focuses Queued;
- event refreshes update upcoming and history snapshots;
- idle rendering performs no extra SQL, queue reads, or flushes.

### Config and keymap tests

- `B` maps to `toggle_queued_pane` in both interactive pane scopes;
- toggling writes one replaceable managed block and survives restart;
- theme, art mode, and queued managed blocks coexist;
- external hot reload updates visibility and width;
- boolean settings accept both `true` and `false`;
- invalid widths and formatters retain the previous active config.

### Regression and documentation

- shared row-helper tests preserve TracksPane selected colors, formatter
  styles, clipping, and flat queue identity;
- existing Playback Queue navigation, filtering, removal, and ordering tests
  stay green;
- update README navigation, configuration reference, and file map;
- update `examples/config.rb` with commented queued-pane settings;
- run the full suite with `mise exec -- bundle exec rake test`.
