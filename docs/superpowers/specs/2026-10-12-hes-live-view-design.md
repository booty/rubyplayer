# HES Live View Design

Status: proposed, 2026-10-12. This is a design for review, not a description of shipped behavior.

## Outcome

When a `.hes` subtune plays, Now Playing opens a full-screen **HES LIVE** page. It lists the six PC Engine PSG voices in libgme's order (Wave 1–4, Multi 1–2), shows their current state, pitch where meaningful, stereo balance, nominal level, sound mode, 32-step wave, and recent note history. Up/Down selects a voice; `M` mutes it and `S` solos it. Tab switches between Live and Info. The page follows the audio being heard, including after a seek or while paused.

Wave mode shows the 12-bit period and a pitch derived from libgme's 7,159,091 Hz PSG clock and its 32 samples at two clocks per sample: `hz = cpu_clock_hz / (64 * period)` for a positive period. Multi 1–2 may instead use noise; direct DAC mode has no stable note. The page labels those modes rather than inventing a pitch. The level bar describes the emulator's current left/right gain and is labeled an estimate of audible level; the wave or DAC sample can also affect actual sound. HES has no separate envelope generator in this libgme PSG model. Do not imply that libgme's unimplemented HES LFO or an ADPCM voice is rendered by the page.

## Data flow

Extend the vendored libgme 0.6.5 build with its HES emulator and six-voice PSG. A local `librp_hes.dylib` uses the existing `rp::Recorder` and `rp::Player` infrastructure. Instrument PSG writes, driver calls, and the end of each emulated frame without changing emulation output. Native snapshots carry the state heard at output-frame positions, with explicit trigger bits for note history. Snapshot volume is bounded: retain audible transitions and retriggers, coalesce ordinary register changes, and never publish one snapshot per direct DAC sample.

The shared `Backends::NativeGme::Handle` decodes `.hes`; libgme continues to scan metadata and `.m3u` subtunes. `PlaybackEngine::ChipState` and `ChipTimeline` carry the HES records already used for GBS/NSF. `Hes::Tracker` converts them to `Vgm::Snapshot` and note history. `UI::ChipLiveView` renders them through a focused HES panel module, and `UI::App` connects the page to the current track and shared voice-muting controls. Runtime dependency checks build the new dylib when missing or unloadable.

## Non-negotiable behavior

- Native audio matches installed libgme sample for sample across the real HES fixtures, including `.m3u` track mapping, mute, seek, silence handling, and fade.
- Keep metadata extraction on libgme, including titles, lengths, and sibling `.m3u` files inside extracted archives. Do not rescan unchanged files or alter database schema.
- Voice bits 0–5 map directly to libgme's six PSG voices. A solo mask includes all six, even while some channels are silent.
- The page observes output already consumed by the audio device; decoder read-ahead cannot advance it. Seeking and changing tracks reset native snapshot and note history state.
- The native callback and idle UI path do no HES rendering or polling. Decoder FFI operations that may emulate use `blocking: true`.
- On small terminals, all six channels remain accessible through scrolling and no draw escapes the modal rectangle.

## Evidence and limits

Use `test/support/rip_fixtures.rb` for `air_zonk`, `alien_crush`, `blazing_lazers`, and `dungeon_explorer`; the latter three live in archives with sibling playlists. Compare native output to Homebrew libgme with `test/support/native_parity.rb`. Use real fixture playback to validate snapshots and the rendered page, and small constructed records for exact register-mode and note-history assertions.

The vendored sources must match the project's existing [libgme 0.6.5 source](https://github.com/libgme/game-music-emu/tree/0.6.5/gme). That version's HES implementation contains `Hes_Emu`, `Hes_Cpu`, `Hes_Apu`, and `Hes_Apu_Adpcm`; its PSG has six oscillators, a 32-byte wave per oscillator, a gate and DAC mode in the control register, and noise on voices 5–6. Source-specific read-only accessors and hook calls belong in `ext/gme/VENDOR.md` so future upstream updates preserve them.
