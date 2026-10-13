/* Force-included (-include) into every vendored libgme HES source file.
 *
 * libgme leaves two instrumentation macros undefined unless the build
 * supplies them (Classic_Emu.h). Defining them here lets rp_hes observe
 * every PSG register write and every music-driver interrupt without editing
 * the emulator sources. Both expand inside Hes_Emu member functions, so they
 * may read its CPU time.
 *
 * Unlike the Game Boy APU, the HuC6280 PSG has no envelopes or length
 * counters: what is heard changes only when a register is written. So no
 * frame-end hook is needed; a write's effect is observed at the next hook. */
#ifndef RP_HES_HOOKS_H
#define RP_HES_HOOKS_H

class Hes_Emu;

void rp_hes_apu_write( Hes_Emu*, int reg, int data, long clock );
void rp_hes_driver_call( Hes_Emu*, long clock );

/* Expands in Hes_Emu::cpu_write_, before the write reaches the PSG, with the
 * time libgme clamps the write to (a block transfer can overrun the frame). */
#define GME_APU_HOOK( emu, addr, data ) rp_hes_apu_write( (emu), (addr), (data), min( time(), end_time() + 8 ) )

/* Expands in Hes_Emu::cpu_done as a VDP or (near-60 Hz) timer interrupt is
 * taken: the previous driver call has returned and this one starts now. */
#define GME_FRAME_HOOK( emu ) rp_hes_driver_call( (emu), time() )

#endif
