# Vendored: libgme GBS core (from libgme 0.6.5)

Source: <https://github.com/libgme/game-music-emu>, tag `0.6.5`, directory `gme/`.
These are the files libgme needs to play `.gbs` through its own C API: the Game Boy CPU and
APU, the `Music_Emu`/`Classic_Emu` playback framework (fades, silence handling), the
`Effects_Buffer` libgme builds GBS emulators with, and `gme.cpp` itself. The version matches the
Homebrew libgme rubyplayer links for every other format, so `.gbs` playback through `rp_gbs`
matches libgme sample for sample (`test/gbs_native_parity_test.rb`).

License: GNU LGPL 2.1 (`COPYING`, copied from libgme's `license.txt`).

## Files

| File | Purpose |
|---|---|
| `Gbs_Emu.{h,cpp}`, `Gb_Cpu.{h,cpp}`, `gb_cpu_io.h` | GBS loading, LR35902 CPU, driver timing |
| `Gb_Apu.{h,cpp}`, `Gb_Oscs.{h,cpp}` | Game Boy APU (2 squares, wave, noise) |
| `Music_Emu.{h,cpp}`, `Classic_Emu.{h,cpp}`, `Gme_File.{h,cpp}` | libgme playback framework |
| `Multi_Buffer.{h,cpp}`, `Effects_Buffer.{h,cpp}`, `Blip_Buffer.{h,cpp}` | Band-limited synthesis and stereo mixing |
| `Data_Reader.{h,cpp}`, `M3u_Playlist.{h,cpp}` | Loading (M3U support is linked in by `Gme_File`) |
| `gme.{h,cpp}` | libgme's C API, used by `rp_gbs` to build the emulator exactly as libgme does |
| `gme_types.h` | Hand-written: enables only `USE_GME_GBS` |
| `blargg_common.h`, `blargg_config.h`, `blargg_endian.h`, `blargg_source.h` | Shared support headers |

## Build flags (required)

- `-DBLARGG_LITTLE_ENDIAN=1`, `-DNDEBUG`, `-std=c++11`: as for `ext/snes_spc`.
- `-include ext/rp_gbs/rp_gbs_hooks.h`: defines libgme's `GME_APU_HOOK` and `GME_FRAME_HOOK`
  instrumentation macros (empty by default in `Classic_Emu.h`) so `rp_gbs` sees every APU
  write and music-driver call, plus `RP_GBS_FRAME_END_HOOK` for the patched call below.
- `-fvisibility=hidden -fvisibility-inlines-hidden`: these classes and `gme_*` functions also
  exist in Homebrew libgme, loaded into the same process; only `rp_gbs_*` is exported.

## Local patch (the only source changes)

Read-only accessors, one call libgme already makes internally, and one hook call. They change
no output.

`Gbs_Emu.h`, public, after `header()`:

```cpp
	// rubyplayer patch: read-only APU and driver timing for live state snapshots.
	Gb_Apu const& rp_apu() const { return apu; }
	blip_time_t rp_play_period() const { return play_period; }
	void rp_catch_up( blip_time_t time ) { apu.rp_catch_up( time ); }
```

`Gb_Apu.h`, public, after `set_tempo()`:

```cpp
	// rubyplayer patch: read-only state for live state snapshots.
	uint8_t const* rp_regs() const { return regs; }
	Gb_Osc const& rp_osc( int i ) const { return *oscs [i]; }
	int rp_sweep_freq() const { return square1.sweep_freq; }
	// When the next 256 Hz frame-sequencer step (length, envelope, sweep) is due.
	blip_time_t rp_next_frame_time() const { return next_frame_time; }
	// Runs the oscillators to `time` (as any register read does) so their
	// envelope and length state is current; output is unchanged.
	void rp_catch_up( blip_time_t time ) { run_until( time ); }
```

`Gbs_Emu.cpp`, in `Gbs_Emu::run_clocks`, just before `apu.end_frame( cpu_time );`, so the
frame's last stretch is observed before the APU runs it unseen:

```cpp
	// rubyplayer patch: see ext/rp_gbs/rp_gbs_hooks.h.
	RP_GBS_FRAME_END_HOOK( this, cpu_time );
```

`Music_Emu.h`, public, after `track_ended()`:

```cpp
	// rubyplayer patch: samples emulated so far, to map emulator time to
	// output time across leading-silence skipping.
	long rp_emu_time() const { return emu_time; }
```

To update: re-download the files from the new tag, replace `gme_types.h` with the GBS-only
version, re-apply this patch, and rerun the parity tests (`test/gbs_native_parity_test.rb`).
