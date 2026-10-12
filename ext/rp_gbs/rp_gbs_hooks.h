/* Force-included (-include) into every vendored libgme GBS source file.
 *
 * libgme leaves two instrumentation macros undefined unless the build
 * supplies them (Classic_Emu.h). Defining them here lets rp_gbs observe
 * every APU register write and every music-driver call without editing
 * the emulator sources. Both expand inside Gbs_Emu member functions, so
 * they may read its private clock. */
#ifndef RP_GBS_HOOKS_H
#define RP_GBS_HOOKS_H

class Gbs_Emu;

void rp_gbs_apu_write( Gbs_Emu*, int reg, int data, long clock );
void rp_gbs_driver_call( Gbs_Emu*, long clock );

/* Expands in Gbs_Emu::cpu_write, before the write reaches the APU. */
#define GME_APU_HOOK( emu, addr, data ) rp_gbs_apu_write( (emu), (addr), (data), clock() )

/* Expands in Gbs_Emu::run_clocks right after the play routine is called:
 * the previous call has returned and cpu_time is the new call's start.
 * (clock() would subtract the CPU's leftover cycles a second time here.) */
#define GME_FRAME_HOOK( emu ) rp_gbs_driver_call( (emu), cpu_time )

#endif
