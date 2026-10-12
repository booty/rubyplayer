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

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rp_spc rp_spc;

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
void rp_spc_mute_voices(rp_spc*, int mask);

/* Live state snapshots (filled in by later work; see tmp/snes_spc.md T6). */
int  rp_spc_snapshot_size(void);
int  rp_spc_snapshot_count(rp_spc*);
const void* rp_spc_snapshots(rp_spc*);
void rp_spc_copy_ram(rp_spc*, unsigned char* out);   /* copies 0x10000 bytes */

#ifdef __cplusplus
}
#endif

#endif
