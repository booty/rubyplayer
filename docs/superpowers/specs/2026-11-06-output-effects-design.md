# Output effects rack

Status: **current**, 2026-11-06. User approved the design.

## Intent and scope

Give RubyPlayer the playful, opinionated sound modes of a shelf stereo, with
enough subtlety for everyday listening and enough range to get strange. Effects
apply to all audio, including Focus sounds. This is an output effect, not a
change to decoded files or emulated chip state. It does not try to model a
specific piece of hardware or provide a general-purpose mixing console.

## Experience

A dedicated Effects panel lists eight independently switchable effects. Each
has one intensity control, from subtle at the low end to exaggerated at the
high end. Several effects can run together. Their order is fixed and chosen to
make combinations sound sensible; users do not rearrange the chain. Defaults
should be musically useful starting points, with final sound tuned by listening.

| Effect | Character |
| --- | --- |
| Arcade Cabinet | Punchy mids, speaker coloration and a little grit. |
| Music Hall | Diffuse room-to-hall reverberation and spaciousness. |
| Tube Amp | Soft saturation and added harmonics, from warmth to crunch. |
| Echo Chamber | Clearly audible repeating delay with controlled feedback; distinct from reverb. |
| Cassette Deck | Softened highs, saturation and increasingly audible slow pitch wobble. |
| AM Radio | Narrow, mid-forward broadcast coloration. |
| Underwater | Muffled, slowly moving filtered sound. |
| Mega Bass | Increasingly exuberant bass emphasis. |

All effects start off on every launch; settings are session-only. Toggling an
effect off retains its intensity for the session. A master bypass temporarily
returns to clean audio without changing enabled effects or intensities. The
panel shows the selected effect, each enabled state and intensity, and master
bypass status; it supports keyboard navigation, toggling, adjustment and
closing. It remains usable in narrow and short terminals, with scrolling if
needed. The implementation chooses collision-safe bindings consistent with the
existing keymap and preserves normal playback controls while the panel is open.

## Approach

Two locations were considered. Processing before the native output ring keeps
DSP outside the audio callback, but the existing buffered audio would delay
control changes and bypass comparisons. The selected approach processes at the
native output, when the callback consumes audio, so controls respond without
waiting for decoder read-ahead. The existing native callback never calls Ruby;
that boundary remains intact.

The rack uses bounded, preallocated per-device DSP state and a fixed signal
chain, designed for the device sample rate. UI changes cross the thread
boundary through safe, nonblocking control state. The callback does not
allocate, wait on locks, perform I/O or call Ruby. Changes are smoothed to
avoid clicks, including toggles and master bypass. Once transitions complete,
master bypass and an entirely disabled rack pass PCM through unchanged.
Enabled combinations use headroom and output protection to avoid runaway
feedback, non-finite samples and damaging digital clipping. Delay and reverb
memory and feedback are bounded. These protections must not alter the fully
bypassed signal.

The callback owns mutable DSP history. Flush and control operations request
changes without concurrently clearing that history; reset work and control
reads must have bounded callback cost, including during rapid UI updates.
Only source frames actually consumed from the ring are processed; silence
padding remains silence. As with the existing flush, one device period already
copied by the callback may still be emitted.

Pause emits silence and holds effect state; resume continues it. A seek, skip,
or source change clears time-based effect history so echoes from the previous
position or source do not leak into the new one. While bypassed or an effect is
off, its history is cleared or otherwise managed so re-enabling it cannot
release stale audio; switching is smoothed. Underrun and end-of-source output
retain the existing silence and playback-position contract: the rack does not
invent consumed source frames or keep playback alive to finish a tail.

The existing spectrum tap and chip views remain source-oriented, so they need
not reflect the processed output. Effect state is separate from persisted
configuration and library metadata.

## Verification and acceptance

- Native deterministic tests cover clean bit-identical bypass, nontrivial
  output for every effect, bounded finite output at extreme combinations,
  independently adjustable effects, stable feedback, transitions, state
  reset, pause/underrun behavior and sample-rate handling.
- UI and integration tests cover panel navigation, simultaneous effects,
  independent intensity retention, master bypass, clean startup, Focus and
  normal playback, and small terminal layouts.
- Verify that callback work is bounded and the idle CPU behavior is preserved;
  run the native compile, full suite and RuboCop. Existing audio parity tests
  must continue to pass with effects off.
- Listen to representative chiptunes, tracker music, ordinary audio and Focus
  sounds at low and high intensities, alone and in combinations. Tune by ear;
  automated signal tests cannot establish whether a preset sounds good. The
  user should be able to audition and give feedback on the tuning before it is
  treated as final.

## Builder decisions

Choose exact DSP algorithms, fixed ordering, default intensities and panel
keybindings during planning and implementation, subject to the behavior above.
Avoid adding dependencies unless they materially improve sound and fit the
native build and real-time constraints.
