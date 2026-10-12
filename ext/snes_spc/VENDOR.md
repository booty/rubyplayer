# Vendored: snes_spc (from libgme 0.6.5)

Source: <https://github.com/libgme/game-music-emu>, tag `0.6.5`, directory `gme/`.
This is the SPC700 + S-DSP core libgme's own `Spc_Emu` uses, plus the output filter and
resampler it pairs them with. Version matches the Homebrew libgme rubyplayer links for every
other format, so `.spc` playback through `rp_spc` should match libgme sample for sample.

License: GNU LGPL 2.1 (`COPYING`, copied from libgme's `license.txt`).

## Files

| File | Purpose |
|---|---|
| `Snes_Spc.{h,cpp}`, `Spc_Cpu.{h,cpp}` | SPC700 CPU, timers, SPC file loading |
| `Spc_Dsp.{h,cpp}` | S-DSP (8 voices, BRR, envelopes, echo) |
| `Spc_Filter.{h,cpp}` | Output filter/gain stage (`SPC_Filter`) |
| `Fir_Resampler.{h,cpp}` | 32 kHz → device-rate resampler |
| `blargg_common.h`, `blargg_config.h`, `blargg_endian.h`, `blargg_source.h` | Shared support headers |

No other libgme files are needed; every `#include` resolves inside this directory
(`config.h` is only included when `HAVE_CONFIG_H` is defined, which we never do).

## Build flags (required)

- `-DBLARGG_LITTLE_ENDIAN=1` — libgme's build system defines byte order; `blargg_endian.h`
  refuses to compile without it. All supported Macs are little-endian.
- `-DNDEBUG` — matches a release libgme build (disables internal asserts).
- `-std=c++11` — `Snes_Spc.h` uses `alignas`.

## Local patch (the only source change)

Read-only accessors so `rp_spc` can snapshot DSP state while decoding. They change no
behavior.

`Snes_Spc.h`, in the public section after `smp_ram()`:

```cpp
	// rubyplayer patch: read-only DSP access for live state snapshots.
	Spc_Dsp const& rp_dsp() const { return dsp; }
```

`Spc_Dsp.h`, in the public section after `out_pos()`:

```cpp
	// rubyplayer patch: read-only voice state for live state snapshots.
	int rp_voice_env(int v) const      { return m.voices [v].env; }
	int rp_voice_env_mode(int v) const { return (int) m.voices [v].env_mode; }
	int rp_voice_brr_addr(int v) const { return m.voices [v].brr_addr; }
```

To update: re-download the files from the new tag, re-apply this patch, and rerun the parity
tests (`test/snes_spc_parity_test.rb`).
