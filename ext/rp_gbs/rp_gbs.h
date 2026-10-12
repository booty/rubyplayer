/* rp_gbs: Game Boy Sound (.gbs) playback for rubyplayer on the vendored
 * libgme GBS core (ext/gme_gbs).
 *
 * Builds the emulator through libgme's own gme_open_data path, so output
 * matches Homebrew libgme sample for sample, and records Game Boy APU state
 * snapshots while decoding for the Now Playing live view.
 *
 * Audio is little-endian float32 interleaved stereo. Every function tolerates
 * a NULL handle. Handles are not thread-safe: use one from one thread. */
#ifndef RP_GBS_H
#define RP_GBS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_GBS_API __attribute__((visibility("default")))

typedef struct rp_gbs rp_gbs;

/* APU state at one moment. 80 bytes, no implicit padding; Ruby unpacks it
 * with 'l<C48C4CCCxS<4S<x2L<L<'. */
typedef struct {
	int32_t  frame;        /* output frame, relative to the first frame of the
	                          rp_gbs_play call that returned it, at which this
	                          state is heard (may exceed that call's length) */
	uint8_t  regs[48];     /* $FF10-$FF3F as last written (wave RAM at 32..47);
	                          sweep updates square 1's frequency registers */
	uint8_t  volume[4];    /* current envelope volume 0..15 (wave: NR32 code) */
	uint8_t  playing;      /* bit i: oscillator i is producing sound */
	uint8_t  enabled;      /* bit i: NR52 status (on, length not expired) */
	uint8_t  triggers;     /* bit i: oscillator i was triggered since the
	                          previous snapshot */
	uint8_t  pad0;
	uint16_t length[4];    /* length counter, in 1/256 s ticks */
	uint16_t sweep_freq;   /* square 1 sweep shadow frequency */
	uint16_t pad1;
	uint32_t play_period;  /* CPU clocks between music-driver calls */
	uint32_t clock_rate;   /* CPU clocks per second */
} rp_gbs_snapshot;

/* Returns NULL when the data is not a loadable GBS file. */
RP_GBS_API rp_gbs* rp_gbs_open(const void* data, long size, int out_rate);
RP_GBS_API void rp_gbs_close(rp_gbs*);

/* Same as gme_load_m3u_data: a sibling playlist that remaps track numbers
 * (and names their lengths). Call before rp_gbs_start_track. 1 on success. */
RP_GBS_API int  rp_gbs_load_m3u(rp_gbs*, const void* data, long size);

/* 1 on success. Discards recorded snapshots. */
RP_GBS_API int  rp_gbs_start_track(rp_gbs*, int track);
/* Same as gme_set_fade: fades over 8 s from start_ms. */
RP_GBS_API void rp_gbs_set_fade(rp_gbs*, long start_ms);
/* Same as gme_ignore_silence. */
RP_GBS_API void rp_gbs_ignore_silence(rp_gbs*, int ignore);

/* Fills `frames` frames (silence after the track ends) and returns 1, or 0
 * on an emulation error. */
RP_GBS_API int  rp_gbs_play(rp_gbs*, float* out, long frames);
RP_GBS_API int  rp_gbs_track_ended(rp_gbs*);
RP_GBS_API int  rp_gbs_seek(rp_gbs*, long ms);   /* 1 on success */
RP_GBS_API long rp_gbs_tell_ms(rp_gbs*);
/* Same as gme_mute_voices: bit 0 square 1, 1 square 2, 2 wave, 3 noise. */
RP_GBS_API void rp_gbs_mute_voices(rp_gbs*, int mask);

/* Snapshots recorded during the most recent rp_gbs_play call, in order, one
 * per music-driver call (at most one per ~4 ms). Valid until the next play. */
RP_GBS_API int  rp_gbs_snapshot_size(void);
RP_GBS_API int  rp_gbs_snapshot_count(rp_gbs*);
RP_GBS_API const rp_gbs_snapshot* rp_gbs_snapshots(rp_gbs*);
/* Replaces the snapshots with one of the current state at frame 0 (the next
 * play's first frame) without emulating. Use after a seek. */
RP_GBS_API void rp_gbs_capture_now(rp_gbs*);

#ifdef __cplusplus
}
#endif

#endif
