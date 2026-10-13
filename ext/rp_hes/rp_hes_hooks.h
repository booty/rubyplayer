/* Force-included (-include) into every vendored libgme HES source file.
 *
 * libgme leaves its GME_APU_HOOK and GME_FRAME_HOOK instrumentation macros
 * undefined unless the build supplies them (Classic_Emu.h). rp_hes does not
 * observe the PSG yet, so they keep libgme's empty defaults. */
#ifndef RP_HES_HOOKS_H
#define RP_HES_HOOKS_H

#endif
