/* rp_spc: SPC playback for rubyplayer on top of the vendored snes_spc core.
 *
 * Reproduces libgme's Spc_Emu + Music_Emu pipeline (resampling, gain, fade,
 * silence handling) so output matches libgme sample for sample, and records
 * S-DSP state snapshots while decoding for the Now Playing live view.
 *
 * Audio is little-endian float32 interleaved stereo. Every function tolerates
 * a NULL handle. Handles are not thread-safe: use one from one thread. */
#ifndef RP_SPC_H
#define RP_SPC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rp_spc rp_spc;

/* S-DSP state at one moment. 176 bytes, no implicit padding; Ruby unpacks it
 * with 'L<C128S<8C8S<8Cx3'. */
typedef struct {
	uint32_t frame;        /* output frame, relative to the first frame of the
	                          rp_spc_play call that returned it, at which this
	                          state is heard (may exceed that call's length) */
	uint8_t  regs[128];    /* DSP registers, including live ENVX/OUTX */
	uint16_t env[8];       /* envelope level, 0..0x7FF */
	uint8_t  env_mode[8];  /* 0 release, 1 attack, 2 decay, 3 sustain */
	uint16_t brr_addr[8];  /* address of the BRR block being decoded */
	uint8_t  attack_edges; /* bit v: voice v started a note since the previous
	                          snapshot (approximate: entered attack, left release,
	                          or changed sample) */
	uint8_t  pad[3];
} rp_spc_snapshot;

/* Returns NULL when the data is not a loadable SPC file. */
rp_spc* rp_spc_open(const void* data, long size, int out_rate);
void rp_spc_close(rp_spc*);

/* Fade starts at start_ms and lasts length_ms; start_ms < 0 disables fading. */
void rp_spc_set_fade(rp_spc*, long start_ms, long length_ms);
/* Nonzero disables leading-silence skipping and silence-based track end.
 * Restarts the track from the beginning so the leading-silence rule applies;
 * call it right after open. */
void rp_spc_set_ignore_silence(rp_spc*, int ignore);

/* Always fills `frames` frames (silence after the track ends) and returns frames. */
long rp_spc_play(rp_spc*, float* out, long frames);
int  rp_spc_track_ended(rp_spc*);
int  rp_spc_seek(rp_spc*, long ms);   /* 1 on success */
long rp_spc_tell_ms(rp_spc*);
/* Same as libgme's mute: silence detection still sees the result, so muting
 * everything can end the track. Pair with rp_spc_pause_silence_detection
 * for interactive muting. */
void rp_spc_mute_voices(rp_spc*, int mask);
/* Nonzero suspends silence-based track ending (fades still end tracks);
 * resuming restarts the silence window. Does not restart the track. */
void rp_spc_pause_silence_detection(rp_spc*, int paused);

/* Snapshots recorded during the most recent rp_spc_play call, in order: one
 * per emulator call, about every 50 ms when resampling (at a 32 kHz output
 * rate, one per libgme-sized play block). Denser capture would change the
 * audio; see play_and_filter. Valid until the next rp_spc_play. */
/* Replaces the snapshots with one of the current state at frame 0 (the next
 * play's first frame) without emulating. Use after a seek. */
void rp_spc_capture_now(rp_spc*);
int  rp_spc_snapshot_size(void);
int  rp_spc_snapshot_count(rp_spc*);
const rp_spc_snapshot* rp_spc_snapshots(rp_spc*);
void rp_spc_copy_ram(rp_spc*, unsigned char* out);   /* copies 0x10000 bytes */

#ifdef __cplusplus
}
#endif

#endif
