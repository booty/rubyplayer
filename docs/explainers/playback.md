# Playback sequence

Status: **current**, reviewed 2026-10-10 against implementation.

This follows normal finite-track playback after Enter selects a track. It
assumes the track opens successfully and is not skipped by the disliked-track
rule. See the [component map](components.md) for thread boundaries.

```mermaid
sequenceDiagram
    actor User
    participant App as UI::App (main thread)
    participant Engine as PlaybackEngine
    participant Queue as PlayQueue
    participant Decoder as Engine decoder thread
    participant Cache as ArchiveCache
    participant Backend as Registry / backend handle
    participant Audio as AudioOutput / native ring
    participant Callback as miniaudio callback
    participant Bus as EventBus

    User->>App: Enter on selected track
    App->>Engine: enqueue_now(selected_tracks)
    Engine->>Queue: enqueue_now under mutex
    Queue->>Bus: on_change publishes queue_changed
    Engine->>Decoder: enqueue play_head command
    Decoder->>Queue: Read head under mutex
    opt Track is inside an archive
        Decoder->>Cache: materialize(physical_path, archive_entry)
        Cache-->>Decoder: Real extracted path
    end
    Decoder->>Backend: backend_for(path), open(path, subtune_index, sample_rate)
    Backend-->>Decoder: Decoder handle
    Decoder->>Audio: Pause, flush old frames, unpause
    Note over Decoder: Set current track and timing baseline, reset LevelTap
    Decoder->>Bus: Publish track_started and playback_state

    loop While playing and not paused
        Decoder->>Backend: handle.read(chunk_frames)
        Backend-->>Decoder: Packed float32 stereo PCM
        Note over Decoder: Push PCM into LevelTap, retain pending bytes
        Decoder->>Audio: Read frames_played
        Decoder->>Bus: Publish position when displayed second changes
        Decoder->>Audio: write(pending)
        Audio-->>Decoder: Number of frames accepted
        Note over Decoder,Audio: Retry unwritten remainder, briefly yield when ring is full
    end

    Note over Audio,Callback: Callback runs independently at the device pace
    Callback->>Audio: Consume available ring frames
    Audio-->>Callback: PCM, plus silence on pause or underrun
    Note over Callback: Send frames to audio device, never call Ruby

    Bus-->>App: Self-pipe wakes IO.select
    App->>Bus: drain
    App->>Engine: Read state, queue snapshots, and levels
    Note over App: Refresh panes, fetch artwork on track_started, render changed cells

    Backend-->>Decoder: nil at end of track
    Note over Decoder: Record history if playback threshold met
    Decoder->>Bus: Publish track_ended
    Decoder->>Queue: advance! under mutex
    Note over Decoder: Close handle, open next track or stop and flush
```

## Timing and ownership

This is a logical walkthrough, not a schedule: UI event draining and the native
callback run concurrently with decoding. `pump` alternates between reading a
chunk and writing pending PCM; it does not discard a chunk when the ring accepts
only part of it. Position notifications are checked after chunk reads and
throttled to changes in the displayed second.

Playback position comes from **consumed** native frames, adjusted for the track
baseline and seek offset. Decoded frames may be buffered ahead of what is heard.
History uses this playback position and is recorded during finish/stop handling
only if the configured duration percentage (or unknown-duration seconds) is met.

Pause and seek enter through the command queue. Paused and idle decoding blocks
on that queue. A seek pauses and flushes old audio, seeks the handle, resets
pending PCM and timing, then restores pause state.

Open or decode failures flag the track as errored, publish `:track_error`, and
advance the queue. Recovery keeps the decoder thread alive. Focus sounds use a
different source: SoX PCM via `FocusPlayer`, pumped by the same decoder thread;
they preserve the finite queue and bypass playback history.

## Source entry points

| Step | Source and methods |
|---|---|
| Selection and command routing | [UI::App](../../lib/rubyplayer/ui/app.rb): `play_now`, `enqueue`, `handle_events` |
| Decoder lifecycle | [PlaybackEngine](../../lib/rubyplayer/playback_engine.rb): `enqueue_now`, `run`, `play_head`, `open_and_play`, `pump`, `finish_and_advance`, `record_history` |
| Ordered tracks | [PlayQueue](../../lib/rubyplayer/play_queue.rb) |
| Archive path resolution | [ArchiveCache](../../lib/rubyplayer/archive_cache.rb): `materialize` |
| Format selection and decoding | [Registry](../../lib/rubyplayer/backends/registry.rb), [GME](../../lib/rubyplayer/backends/gme.rb), [OpenMPT](../../lib/rubyplayer/backends/openmpt.rb), [FFmpeg](../../lib/rubyplayer/backends/ffmpeg.rb) |
| PCM transport and device callback | [AudioOutput](../../lib/rubyplayer/audio_output.rb): `write`, `frames_played`; [C shim](../../ext/rp_audio/rp_audio.c): `rp_write`, `data_callback` |
| UI wakeup | [EventBus](../../lib/rubyplayer/event_bus.rb): `publish`, `drain` |

[Component map](components.md) · [Library scan sequence](scanning.md) · [Project README](../../README.md#architecture)
