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

/* PSG state at one moment. 8 bytes; Ruby does not unpack it yet. */
typedef struct {
	int32_t  frame;        /* output frame, relative to the first frame of the
	                          rp_hes_play call that returned it, from which this
	                          state is heard */
	uint8_t  triggers;     /* bit i: voice i started a note since the previous
	                          snapshot */
	uint8_t  pad[3];
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

/* Snapshots recorded during the most recent rp_hes_play call, in order.
 * Valid until the next play. */
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
