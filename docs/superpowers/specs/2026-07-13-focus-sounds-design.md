# Focus Sounds Design

## Goal

Add a `Focus` special item below `Favorite Tracks` in the Library pane. Its
Tracks pane view exposes six hardcoded, infinite SoX noise recipes:

- Green
- Rain
- Fan
- Brown
- Beach Rain
- Beach Rain (Dark)

Focus sounds do not enter the playback queue, database, ratings, or history.

## UI Behavior

`Focus` behaves as a top-level Library special row. Selecting it shows the six
focus sound entries in their declared order. They use the existing Tracks pane
navigation and formatting, but are not database-backed `Track` records.

`Enter` plays the selected focus sound immediately. Queue actions (`q` and
`n`) do not apply and show a status message explaining that focus sounds cannot
be queued. The track-info action also does not apply.

## Playback Behavior

A new `FocusPlayer` owns one SoX child process at a time. Each recipe is
started as a direct `play -n synth ...` invocation using an argument array;
no shell command string is evaluated. The process runs indefinitely because
the recipes have no duration.

Starting a focus sound stops ordinary queue playback but leaves queue contents
unchanged. Starting any normal track stops the current focus process before
queue playback begins. Skipping, pausing, or queue edits do not restart focus
playback. App shutdown always stops the process.

`FocusPlayer` starts the child in its own process group, sends `TERM` to stop
the process group, waits briefly, then sends `KILL` only if necessary. Missing
SoX and spawn failures produce a status/error event without crashing the UI.

## Components

- `FocusSound`: immutable value object containing title and SoX arguments.
- `FocusSounds`: fixed catalog of six values, including recipe arguments.
- `FocusPlayer`: lifecycle wrapper around spawned SoX `play` process.
- `LibraryPane`: adds `:focus` under `:favorites`.
- `TracksPane`: accepts a focus-source dependency and displays catalog entries
  for `:focus` mode.
- `UI::App`: owns `FocusPlayer`, routes Focus play action, blocks Focus queue
  actions, stops Focus before normal playback, and shuts it down cleanly.

## Tests

- Library pane special-row order and Focus label.
- Tracks pane Focus mode displays catalog in declared order.
- App routes Focus `Enter` to FocusPlayer and rejects queue actions.
- FocusPlayer spawns exact SoX argument arrays, replaces an active sound, and
  terminates its process group on stop.
- Normal track playback stops active Focus playback.

Tests inject process-spawning behavior into `FocusPlayer`; no test requires
SoX or an audio device.
