#ifndef RP_EFFECTS_H
#define RP_EFFECTS_H

#include <stdint.h>

typedef struct rp_effects rp_effects;

enum rp_effect_id {
    RP_EFFECT_AM_RADIO,
    RP_EFFECT_ARCADE,
    RP_EFFECT_TUBE,
    RP_EFFECT_CASSETTE,
    RP_EFFECT_BASS,
    RP_EFFECT_UNDERWATER,
    RP_EFFECT_HALL,
    RP_EFFECT_ECHO,
    RP_EFFECT_COUNT
};

rp_effects *rp_effects_create(unsigned int sample_rate_hz);
void rp_effects_destroy(rp_effects *rack);
void rp_effects_reset(rp_effects *rack);
void rp_effects_process(rp_effects *rack, float *interleaved_stereo,
                        unsigned int frame_count, uint64_t controls, uint32_t reset_mask);

#endif
