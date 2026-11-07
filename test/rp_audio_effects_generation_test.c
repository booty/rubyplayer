#include "../ext/rp_audio/effects.c"
#include <assert.h>

int main(void) {
    rp_effects *rack = rp_effects_create(48000);
    assert(rack);
    rp_delay *delay = &rack->effects[RP_EFFECT_ECHO].delay;
    delay->generation = UINT64_MAX;
    delay_write(delay, 0.5f, 0.5f);
    assert(delay_read(delay, 1, 0) == 0.5f);
    rp_effects_reset(rack);
    assert(delay_read(delay, 1, 0) == 0.0f);
    delay_write(delay, 1.0f, 1.0f);
    rp_effects_reset(rack);
    assert(delay_read(delay, 1, 0) == 0.0f);
    rp_effects_destroy(rack);
    return 0;
}
