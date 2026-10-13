/* rp_hes: PC Engine / TurboGrafx-16 (.hes) playback for rubyplayer on the
 * vendored libgme HES core (ext/gme).
 *
 * Builds the emulator through libgme's own gme_open_data path, so output
 * matches Homebrew libgme sample for sample, and records HuC6280 PSG state
 * snapshots while decoding for the Now Playing live view.
 *
 * Audio is little-endian float32 interleaved stereo. Every function tolerates
 * a NULL handle. Handles are not thread-safe: use one from one thread. */
#ifndef RP_HES_H
#define RP_HES_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_HES_API __attribute__((visibility("default")))

typedef struct rp_hes rp_hes;

/* PSG state at one moment. 268 bytes, no implicit padding; Ruby unpacks it
 * with 'l<C4S<6C24a192s<12L<2'. Bit fields are bit i for voice i. */
typedef struct {
	int32_t  frame;            /* output frame, relative to the first frame of
	                              the rp_hes_play call that returned it, from
	                              which this state is heard */
	uint8_t  playing;          /* bit i: voice i is keyed on, has gain, and
	                              its mode makes sound (wave period >= 7) */
	uint8_t  triggers;         /* bit i: voice i was keyed on since the
	                              previous snapshot */
	uint8_t  master_balance;   /* $801: left volume in bits 4-7, right in 0-3 */
	uint8_t  selected_channel; /* $800: the voice later writes address */
	uint16_t period[6];        /* 12-bit wave timer: clock / (64 * period) Hz */
	uint8_t  control[6];       /* $804: bit 7 key on, bit 6 direct DAC, 0-4 volume */
	uint8_t  balance[6];       /* $805: left volume in bits 4-7, right in 0-3 */
	uint8_t  noise[6];         /* $807 (voices 4-5): bit 7 noise, 0-4 rate */
	uint8_t  dac[6];           /* direct-DAC sample (0 outside DAC mode) */
	uint8_t  wave[6][32];      /* 5-bit wave samples */
	int16_t  output_left[6];   /* libgme's current left and right gains */
	int16_t  output_right[6];
	uint32_t vblank_period_cycles; /* CPU clocks per VBlank (driver period) */
	uint32_t cpu_clock_hz;         /* CPU clocks per second */
} rp_hes_snapshot;

/* Returns NULL when the data is not a loadable HES file. */
RP_HES_API rp_hes* rp_hes_open(const void* data, long data_size_bytes, int output_rate_hz);
RP_HES_API void rp_hes_close(rp_hes*);

/* Same as gme_load_m3u_data: a sibling playlist that remaps track numbers
 * (and names their lengths). Call before rp_hes_start_track. 1 on success. */
RP_HES_API int  rp_hes_load_m3u(rp_hes*, const void* data, long data_size_bytes);

/* 1 on success. Discards recorded snapshots. */
RP_HES_API int  rp_hes_start_track(rp_hes*, int track);
/* Same as gme_set_fade: fades over 8 s from start_ms. */
RP_HES_API void rp_hes_set_fade(rp_hes*, long start_ms);
/* Same as gme_ignore_silence. */
RP_HES_API void rp_hes_ignore_silence(rp_hes*, int ignore);

/* Fills `frames` frames (silence after the track ends) and returns 1, or 0
 * on an emulation error. */
RP_HES_API int  rp_hes_play(rp_hes*, float* out, long frames);
RP_HES_API int  rp_hes_track_ended(rp_hes*);
RP_HES_API int  rp_hes_seek(rp_hes*, long ms);   /* 1 on success */
RP_HES_API long rp_hes_tell_ms(rp_hes*);
/* Same as gme_mute_voices: bits 0-3 Wave 1-4, bits 4-5 Multi 1-2. */
RP_HES_API void rp_hes_mute_voices(rp_hes*, int mask);

/* Snapshots recorded during the most recent rp_hes_play call, in order: one
 * whenever a voice is keyed, sounds, or switches mode (even twice within one
 * driver call), plus the registers each driver call leaves; pending writes
 * are recorded after at most 1/240 s, so DAC streams and timer drivers stay
 * bounded. Valid until the next play. */
RP_HES_API int  rp_hes_snapshot_size(void);
RP_HES_API int  rp_hes_snapshot_count(rp_hes*);
RP_HES_API const rp_hes_snapshot* rp_hes_snapshots(rp_hes*);
/* Replaces the snapshots with those heard from the current position on,
 * without emulating: the state heard there at frame 0 (the next play's first
 * frame), then any libgme already emulated beyond it. Use after a seek. */
RP_HES_API void rp_hes_capture_now(rp_hes*);

#ifdef __cplusplus
}
#endif

#endif
