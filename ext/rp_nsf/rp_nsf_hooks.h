/* Force-included (-include) into every vendored libgme source file of the
 * NSF player.
 *
 * libgme leaves two instrumentation macros undefined unless the build
 * supplies them (Classic_Emu.h): GME_APU_HOOK sees every 2A03 register write
 * and GME_FRAME_HOOK every music-driver call. Expansion chips' writes and
 * the end of each APU time frame have no libgme hook, so the vendored
 * Nsf_Emu.cpp is patched with rubyplayer's own RP_NSF_* hooks there. All
 * expand inside Nsf_Emu member functions, so they may read its CPU time. */
#ifndef RP_NSF_HOOKS_H
#define RP_NSF_HOOKS_H

#ifdef __cplusplus
class Nsf_Emu;

void rp_nsf_apu_write( Nsf_Emu*, unsigned addr, int data, long clock );
void rp_nsf_expansion_write( Nsf_Emu*, unsigned addr, int data, long clock );
void rp_nsf_driver_call( Nsf_Emu*, long clock );
void rp_nsf_frame_end( Nsf_Emu*, long clock );

/* Expands in Nsf_Emu::cpu_write (nes_cpu_io.h), before the write reaches the
 * APU; addr is relative to $4000. */
#define GME_APU_HOOK( emu, addr, data ) rp_nsf_apu_write( (emu), (addr), (data), cpu::time() )

/* Expands in Nsf_Emu::run_clocks right after the play routine is called. */
#define GME_FRAME_HOOK( emu ) rp_nsf_driver_call( (emu), time() )

/* Expands at the top of Nsf_Emu::cpu_write_misc, before an expansion chip
 * sees the write (or it is found unmapped). */
#define RP_NSF_EXPANSION_WRITE_HOOK( emu, addr, data ) rp_nsf_expansion_write( (emu), (addr), (data), time() )

/* Expands in Nsf_Emu::run_clocks just before the chips end their time
 * frame, which would otherwise run the frame's last stretch unobserved. */
#define RP_NSF_FRAME_END_HOOK( emu, end ) rp_nsf_frame_end( (emu), (end) )
#endif

#endif
