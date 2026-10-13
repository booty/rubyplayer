# Vendored: libgme GBS, NSF, and HES cores (from libgme 0.6.5)

Source: <https://github.com/libgme/game-music-emu>, tag `0.6.5`, directory `gme/`.
These are the files libgme needs to play `.gbs`, `.nsf`, `.nsfe`, and `.hes` through its own C API:
the Game Boy, NES, and PC Engine CPUs and sound chips (the 2A03 and every NSF expansion chip
libgme emulates; the HuC6280 PSG and the CD-ROM ADPCM unit),
the `Music_Emu`/`Classic_Emu` playback framework (fades, silence handling), the
`Effects_Buffer` libgme builds these emulators with, and `gme.cpp` itself. The version matches
the Homebrew libgme rubyplayer links for every other format, so playback through `rp_gbs`,
`rp_nsf`, and `rp_hes` matches libgme sample for sample (`test/gbs_native_parity_test.rb`,
`test/nsf_native_parity_test.rb`, `test/hes_native_parity_test.rb`).

License: GNU LGPL 2.1 (`COPYING`, copied from libgme's `license.txt`); `ext/emu2413.{c,h}`
(Mitsutaka Okazaki's YM2413 emulator, used for the VRC7) is MIT (`ext/LICENSE-emu2413`).

## Files

| File | Purpose |
|---|---|
| `Music_Emu.{h,cpp}`, `Classic_Emu.{h,cpp}`, `Gme_File.{h,cpp}` | libgme playback framework |
| `Multi_Buffer.{h,cpp}`, `Effects_Buffer.{h,cpp}`, `Blip_Buffer.{h,cpp}` | Band-limited synthesis and stereo mixing |
| `Data_Reader.{h,cpp}`, `M3u_Playlist.{h,cpp}` | Loading (M3U support is linked in by `Gme_File`) |
| `gme.{h,cpp}` | libgme's C API, used to build each emulator exactly as libgme does |
| `gme_types.h` | Hand-written and empty: each player enables its formats with `-DUSE_GME_*` |
| `blargg_common.h`, `blargg_config.h`, `blargg_endian.h`, `blargg_source.h` | Shared support headers |
| `Gbs_Emu.{h,cpp}`, `Gb_Cpu.{h,cpp}`, `gb_cpu_io.h` | GBS loading, LR35902 CPU, driver timing |
| `Gb_Apu.{h,cpp}`, `Gb_Oscs.{h,cpp}` | Game Boy APU (2 squares, wave, noise) |
| `Nsf_Emu.{h,cpp}`, `Nsfe_Emu.{h,cpp}`, `Nes_Cpu.{h,cpp}`, `nes_cpu_io.h` | NSF and NSFe loading, 6502 CPU, driver timing |
| `Nes_Apu.{h,cpp}`, `Nes_Oscs.{h,cpp}` | 2A03 APU (2 pulses, triangle, noise, DMC); MMC5 reuses it |
| `Nes_Vrc6_Apu`, `Nes_Vrc7_Apu`, `Nes_Fds_Apu`, `Nes_Mmc5_Apu.h`, `Nes_Namco_Apu`, `Nes_Fme7_Apu` | Expansion chips: VRC6, VRC7, FDS, MMC5, Namco 163, Sunsoft 5B |
| `ext/emu2413.{c,h}` | YM2413 core behind the VRC7 |
| `Hes_Emu.{h,cpp}`, `Hes_Cpu.{h,cpp}`, `hes_cpu_io.h` | HES loading, HuC6280 CPU, timer and VDP interrupts (driver timing) |
| `Hes_Apu.{h,cpp}`, `Hes_Apu_Adpcm.{h,cpp}` | HuC6280 PSG (six wave voices, noise on 5-6) and the ADPCM unit |

## Build flags (required)

Each player (`ext/rp_gbs`, `ext/rp_nsf`, `ext/rp_hes`) compiles the framework files plus only its format's
emulator files into its own dylib (see the Rakefile's `gme_player`):

- `-DBLARGG_LITTLE_ENDIAN=1`, `-DNDEBUG`, `-std=c++11`: as for `ext/snes_spc`.
- `-DUSE_GME_GBS`, `-DUSE_GME_NSF -DUSE_GME_NSFE`, or `-DUSE_GME_HES`: which types `gme.cpp`
  registers.
- `-include ext/rp_gbs/rp_gbs_hooks.h` (or `rp_nsf_hooks.h`, `rp_hes_hooks.h`): defines libgme's `GME_APU_HOOK`
  and `GME_FRAME_HOOK` instrumentation macros (empty by default in `Classic_Emu.h`) so the
  player sees every sound-chip write and music-driver call, plus the `RP_*` hooks the patch
  below calls.
- `-fvisibility=hidden -fvisibility-inlines-hidden`: these classes and `gme_*` functions also
  exist in Homebrew libgme, loaded into the same process; only `rp_gbs_*`, `rp_nsf_*`, and `rp_hes_*`
  are exported.
- `ext/emu2413.c` is C: it is compiled on its own (same optimization and visibility flags) and
  linked into the NSF player.

## Local patch (the only source changes)

Read-only accessors, one call libgme already makes internally, and hook calls. They change
no output.

### Shared

`Music_Emu.h`, public, after `track_ended()`:

```cpp
	// rubyplayer patch: samples emulated so far, to map emulator time to
	// output time across leading-silence skipping.
	long rp_emu_time() const { return emu_time; }
```

### GBS

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

### NSF

`Nsf_Emu.h`, public, after `apu_()`:

```cpp
	// rubyplayer patch: read-only chips and driver timing for live state
	// snapshots.
	Nes_Apu const& rp_apu() const { return apu; }
	class Nes_Vrc6_Apu const* rp_vrc6() const { return vrc6; }
	class Nes_Namco_Apu const* rp_namco() const { return namco; }
	class Nes_Fme7_Apu const* rp_fme7() const { return fme7; }
	class Nes_Fds_Apu const* rp_fds() const { return fds; }
	class Nes_Mmc5_Apu const* rp_mmc5() const { return mmc5; }
	class Nes_Vrc7_Apu const* rp_vrc7() const { return vrc7; }
	long rp_play_period() const { return play_period; } // in 1/12 CPU clocks
	double rp_clock_rate() const { return clock_rate_; }
	bool rp_pal() const { return pal_only; }
```

`Nes_Apu.h`, public, after `run_until()`:

```cpp
	// rubyplayer patch: read-only state for live state snapshots.
	Nes_Square const& rp_square( int i ) const { return i ? square2 : square1; }
	Nes_Triangle const& rp_triangle() const { return triangle; }
	Nes_Noise const& rp_noise() const { return noise; }
	Nes_Dmc const& rp_dmc() const { return dmc; }
	int rp_osc_enables() const { return osc_enables; }
	int rp_frame_mode() const { return frame_mode; }
	// Frame counter position, as of rp_last_time() (oscillators run lazily).
	nes_time_t rp_last_time() const { return last_time; }
	int rp_frame() const { return frame; }
	int rp_frame_delay() const { return frame_delay; }
	int rp_frame_period() const { return frame_period; }
```

`Nes_Namco_Apu.h`, before `public: Nes_Namco_Apu();`:

```cpp
	// rubyplayer patch: read-only sound RAM for live state snapshots.
	uint8_t const* rp_regs() const { return reg; }
```

`Nes_Fds_Apu.h`, public, after `write_()`:

```cpp
	// rubyplayer patch: read-only state for live state snapshots.
	unsigned char const* rp_regs() const { return regs_; }
	int rp_env_gain() const { return env_gain; }
	int rp_sweep_gain() const { return sweep_gain; }
	unsigned char const* rp_mod_wave() const { return mod_wave; }
	// Envelope timing, as of rp_last_time() (the channel runs lazily).
	int rp_env_delay() const { return env_delay; }
	int rp_env_speed() const { return env_speed; }
	int rp_lfo_tempo() const { return lfo_tempo; }
	blip_time_t rp_last_time() const { return last_time; }
	bool rp_has_output() const { return output_ != 0; }
```

`Nsf_Emu.cpp`: at the top of `Nsf_Emu::cpu_write_misc`, so expansion chip writes are seen, and
in `Nsf_Emu::run_clocks` just before `apu.end_frame( duration );`:

```cpp
	// rubyplayer patch: see ext/rp_nsf/rp_nsf_hooks.h.
	RP_NSF_EXPANSION_WRITE_HOOK( this, addr, data );
```

```cpp
	// rubyplayer patch: see ext/rp_nsf/rp_nsf_hooks.h.
	RP_NSF_FRAME_END_HOOK( this, duration );
```

### HES

`Hes_Emu.h`, public, after `header()`:

```cpp
	// rubyplayer patch: read-only PSG and driver timing for live state snapshots.
	Hes_Apu const& rp_apu() const { return apu; }
	hes_time_t rp_play_period() const { return play_period; }
```

`Hes_Apu.h`, public, after `end_frame()`:

```cpp
	// rubyplayer patch: read-only state for live state snapshots.
	Hes_Osc const& rp_osc( int i ) const { return oscs [i]; }
	int rp_balance() const { return balance; }
	int rp_latch() const { return latch; }
```

No hook call is patched in: the PSG changes only when written, so libgme's own `GME_APU_HOOK`
and `GME_FRAME_HOOK` (defined in `ext/rp_hes/rp_hes_hooks.h`) observe everything.

To update: re-download the files from the new tag, keep the empty `gme_types.h`, re-apply this
patch, and rerun every parity test.
