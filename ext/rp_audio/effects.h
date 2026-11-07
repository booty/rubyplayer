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

/* Every reset bit set: the whole rack fades out and clears together. */
#define RP_EFFECT_RESET_ALL ((UINT32_C(1) << RP_EFFECT_COUNT) - 1)

/* Controls the output callback has accepted: each effect's target level,
 * 0 (off) to 100 percent, and whether the whole rack is bypassed. */
typedef struct {
    uint8_t intensity_percent[RP_EFFECT_COUNT];
    int bypass;
} rp_effect_controls;

/* Display name for an effect id, or NULL past the last one. The UI reads
 * names from here so its list can never fall out of enum order. */
const char *rp_effect_name(unsigned int id);
unsigned int rp_effect_count(void);

rp_effects *rp_effects_create(unsigned int sample_rate_hz);
void rp_effects_destroy(rp_effects *rack);
void rp_effects_reset(rp_effects *rack);
void rp_effects_process(rp_effects *rack, float *interleaved_stereo,
                        unsigned int frame_count, const rp_effect_controls *controls,
                        uint32_t reset_mask);

#endif
