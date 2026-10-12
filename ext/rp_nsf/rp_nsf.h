/* rp_nsf: NES/Famicom Sound Format (.nsf, .nsfe) playback for rubyplayer
 * on the vendored libgme NSF core (ext/gme).
 *
 * Builds the emulator through libgme's own gme_new_emu path, so output
 * matches Homebrew libgme sample for sample, and records 2A03 and expansion
 * chip state snapshots while decoding for the Now Playing live view.
 *
 * Audio is little-endian float32 interleaved stereo. Every function tolerates
 * a NULL handle. Handles are not thread-safe: use one from one thread. */
#ifndef RP_NSF_H
#define RP_NSF_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RP_NSF_API __attribute__((visibility("default")))

typedef struct rp_nsf rp_nsf;

/* Expansion chip flags, as in the NSF header. */
enum {
	RP_NSF_VRC6 = 0x01, RP_NSF_VRC7 = 0x02, RP_NSF_FDS = 0x04,
	RP_NSF_MMC5 = 0x08, RP_NSF_N163 = 0x10, RP_NSF_S5B = 0x20
};

/* Chip state at one moment. 392 bytes, no implicit padding; Ruby unpacks it
 * with Nsf::Snapshot::FORMAT. Voices are numbered as libgme numbers them
 * (and mutes them): 2A03 square 1, square 2, triangle, noise, DMC, then
 * each present chip's in this order: VRC6 (sawtooth, pulse 1, pulse 2),
 * N163 (8 waves, of which the highest-numbered `active` play), 5B (3),
 * FDS (1), MMC5 (pulse 1, pulse 2, PCM), VRC7 (6). Blocks of absent chips
 * are zero. */
typedef struct {
	int32_t  frame;          /* output frame, relative to the first frame of
	                            the rp_nsf_play call that returned it, from
	                            which this state is heard */
	uint32_t playing;        /* bit v: voice v is producing sound */
	uint32_t triggers;       /* bit v: voice v (re)started since the previous
	                            snapshot (length reload, key on, DMC start) */
	uint32_t play_period;    /* CPU clocks between music-driver calls */
	uint32_t clock_rate;     /* CPU clocks per second (NTSC or PAL) */
	uint8_t  chips;          /* RP_NSF_* flags */
	uint8_t  pal;            /* 1: PAL timing */
	uint8_t  voice_count;
	uint8_t  pad0;

	/* 2A03 */
	uint8_t  apu_regs[20];   /* $4000-$4013, as the oscillators hold them
	                            (sweep rewrites the squares' periods) */
	uint8_t  apu_status;     /* oscillator enables ($4015 bits 0-4) */
	uint8_t  apu_frame_mode; /* $4017 */
	uint8_t  apu_volume[3];  /* envelope output: square 1, square 2, noise */
	uint8_t  tri_linear;     /* triangle linear counter */
	uint8_t  dmc_dac;        /* DMC output level, 0-127 */
	uint8_t  pad1;
	uint16_t apu_length[5];  /* length counters; DMC: sample bytes left */
	uint16_t dmc_address;    /* next sample byte */

	/* MMC5: two more 2A03-style squares and an 8-bit PCM DAC */
	uint8_t  mmc5_regs[8];   /* $5000-$5007 */
	uint8_t  mmc5_status;
	uint8_t  mmc5_volume[2];
	uint8_t  mmc5_pcm;
	uint16_t mmc5_length[2];

	uint8_t  vrc6_regs[9];   /* $9000-2, $A000-2, $B000-2 */
	uint8_t  s5b_regs[14];   /* Sunsoft 5B registers 0-13 */
	uint8_t  vrc7_custom[8]; /* VRC7 custom instrument, registers 0-7 */
	uint8_t  vrc7_regs[18];  /* per channel: $10+c, $20+c, $30+c */

	/* FDS */
	uint8_t  fds_regs[19];   /* $4080-$4092 */
	uint8_t  fds_env_gain;   /* volume envelope output, 0-63 */
	uint8_t  fds_sweep_gain; /* modulation depth, 0-63 */
	uint8_t  pad2;
	uint8_t  fds_wave[64];   /* wave RAM, 6-bit samples */
	uint8_t  fds_mod[32];    /* modulation table, 3-bit steps */

	uint8_t  n163[128];      /* N163 sound RAM (waves and channel registers) */
	uint8_t  n163_active;    /* N163 channels playing, 1-8 */
	uint8_t  pad3[3];
} rp_nsf_snapshot;

/* NULL when the data is not a loadable NSF or NSFe file. */
RP_NSF_API rp_nsf* rp_nsf_open(const void* data, long size, int out_rate);
RP_NSF_API void rp_nsf_close(rp_nsf*);

/* Same as gme_load_m3u_data: a sibling playlist that remaps track numbers
 * (and names their lengths). Call before rp_nsf_start_track. 1 on success. */
RP_NSF_API int  rp_nsf_load_m3u(rp_nsf*, const void* data, long size);

/* 1 on success. Discards recorded snapshots. */
RP_NSF_API int  rp_nsf_start_track(rp_nsf*, int track);
/* Same as gme_set_fade: fades over 8 s from start_ms. */
RP_NSF_API void rp_nsf_set_fade(rp_nsf*, long start_ms);
/* Same as gme_ignore_silence. */
RP_NSF_API void rp_nsf_ignore_silence(rp_nsf*, int ignore);

/* Fills `frames` frames (silence after the track ends) and returns 1, or 0
 * on an emulation error. */
RP_NSF_API int  rp_nsf_play(rp_nsf*, float* out, long frames);
RP_NSF_API int  rp_nsf_track_ended(rp_nsf*);
RP_NSF_API int  rp_nsf_seek(rp_nsf*, long ms);   /* 1 on success */
RP_NSF_API long rp_nsf_tell_ms(rp_nsf*);
/* Same as gme_mute_voices, by voice number (see rp_nsf_snapshot). */
RP_NSF_API void rp_nsf_mute_voices(rp_nsf*, int mask);
RP_NSF_API int  rp_nsf_voice_count(rp_nsf*);

/* Snapshots recorded during the most recent rp_nsf_play call, in order: one
 * whenever the voices sounding or their volumes change (a trigger, a length
 * counter running out, an envelope step), at the moment they change, plus
 * the registers each music-driver call leaves (at most one per ~4 ms).
 * Valid until the next play. */
RP_NSF_API int  rp_nsf_snapshot_size(void);
RP_NSF_API int  rp_nsf_snapshot_count(rp_nsf*);
RP_NSF_API const rp_nsf_snapshot* rp_nsf_snapshots(rp_nsf*);
/* Replaces the snapshots with those heard from the current position on,
 * without emulating: the state heard there at frame 0 (the next play's first
 * frame), then any libgme already emulated beyond it. Use after a seek. */
RP_NSF_API void rp_nsf_capture_now(rp_nsf*);

#ifdef __cplusplus
}
#endif

#endif
