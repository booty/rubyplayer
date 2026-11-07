#include "effects.h"
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define RP_CHANNELS 2
#define RP_TRANSITION_SECONDS 0.01f
#define RP_PI 3.14159265358979323846f
#define RP_DELAY_SECONDS 2u

typedef struct {
    float *samples;
    uint64_t *tags;
    size_t capacity_frames;
    size_t position_frames;
    uint64_t generation;
} rp_delay;

typedef struct {
    float level;
    float low[RP_CHANNELS];
    float high[RP_CHANNELS];
    float phase;
    int resetting;
    rp_delay delay;
} rp_effect_state;

struct rp_effects {
    unsigned int sample_rate_hz;
    float transition_step;
    float bypass_level;
    int bypass_waiting;
    rp_effect_state effects[RP_EFFECT_COUNT];
};

static int delay_init(rp_delay *delay, unsigned int sample_rate_hz) {
    delay->capacity_frames = (size_t)sample_rate_hz * RP_DELAY_SECONDS + 4;
    delay->samples = calloc(delay->capacity_frames * RP_CHANNELS, sizeof(float));
    delay->tags = calloc(delay->capacity_frames, sizeof(uint64_t));
    delay->generation = 1;
    return delay->samples && delay->tags;
}

rp_effects *rp_effects_create(unsigned int sample_rate_hz) {
    if (sample_rate_hz < 8000 || sample_rate_hz > 384000) return NULL;
    rp_effects *rack = calloc(1, sizeof(*rack));
    if (!rack) return NULL;
    rack->sample_rate_hz = sample_rate_hz;
    rack->transition_step = 1.0f / ((float)sample_rate_hz * RP_TRANSITION_SECONDS);
    rack->bypass_level = 1.0f;
    const int delayed[] = {RP_EFFECT_CASSETTE, RP_EFFECT_HALL, RP_EFFECT_ECHO};
    for (size_t i = 0; i < sizeof(delayed) / sizeof(delayed[0]); i++) {
        if (!delay_init(&rack->effects[delayed[i]].delay, sample_rate_hz)) {
            rp_effects_destroy(rack);
            return NULL;
        }
    }
    return rack;
}

void rp_effects_destroy(rp_effects *rack) {
    if (!rack) return;
    for (int i = 0; i < RP_EFFECT_COUNT; i++) {
        free(rack->effects[i].delay.samples);
        free(rack->effects[i].delay.tags);
    }
    free(rack);
}

static void effect_reset(rp_effect_state *state) {
    memset(state->low, 0, sizeof(state->low));
    memset(state->high, 0, sizeof(state->high));
    state->phase = 0;
    if (state->delay.capacity_frames) {
        /* Exhaustion fails closed: never reuse a generation containing old audio. */
        if (state->delay.generation == UINT64_MAX) {
            state->delay.generation = 0;
        } else if (state->delay.generation != 0) {
            state->delay.generation++;
        }
        state->delay.position_frames = 0;
    }
}

void rp_effects_reset(rp_effects *rack) {
    if (!rack) return;
    for (int i = 0; i < RP_EFFECT_COUNT; i++) {
        effect_reset(&rack->effects[i]);
        rack->effects[i].resetting = 0;
    }
}

static float delay_read(const rp_delay *delay, size_t offset_frames, int channel) {
    if (delay->generation == 0) return 0;
    if (offset_frames >= delay->capacity_frames) offset_frames = delay->capacity_frames - 1;
    size_t index = (delay->position_frames + delay->capacity_frames - offset_frames) % delay->capacity_frames;
    return delay->tags[index] == delay->generation ? delay->samples[index * RP_CHANNELS + channel] : 0;
}

static void delay_write(rp_delay *delay, float left, float right) {
    if (delay->generation == 0) return;
    size_t index = delay->position_frames;
    delay->samples[index * RP_CHANNELS] = left;
    delay->samples[index * RP_CHANNELS + 1] = right;
    delay->tags[index] = delay->generation;
    delay->position_frames = (index + 1) % delay->capacity_frames;
}

static float approach(float value, float target, float step) {
    if (value < target) return fminf(value + step, target);
    if (value > target) return fmaxf(value - step, target);
    return value;
}

static float lowpass(float input, float *state, float hz, float rate_hz) {
    float coefficient = 1.0f - expf(-2.0f * RP_PI * hz / rate_hz);
    *state += coefficient * (input - *state);
    return *state;
}

static float saturate(float sample, float drive) {
    return tanhf(sample * drive) / tanhf(drive);
}

static float output_limit(float sample) {
    if (!isfinite(sample)) return 0.0f;
    float magnitude = fabsf(sample);
    if (magnitude <= 0.7f) return sample;
    float excess = magnitude - 0.7f;
    return copysignf(0.7f + 0.3f * (excess / (0.3f + excess)), sample);
}

static void process_effect(rp_effect_state *state, int effect, float intensity,
                           float *left, float *right, float rate_hz) {
    float dry[RP_CHANNELS] = {*left, *right};
    float wet[RP_CHANNELS] = {dry[0], dry[1]};
    float amount = intensity;
    float l, r;
    switch (effect) {
    case RP_EFFECT_AM_RADIO:
        for (int c = 0; c < RP_CHANNELS; c++) {
            float low = lowpass(dry[c], &state->low[c], 450.0f, rate_hz);
            float band = lowpass(dry[c] - low, &state->high[c], 2800.0f, rate_hz);
            wet[c] = saturate(band * 1.6f, 1.2f + amount);
        }
        break;
    case RP_EFFECT_ARCADE:
        for (int c = 0; c < RP_CHANNELS; c++) {
            float low = lowpass(dry[c], &state->low[c], 180.0f, rate_hz);
            float mid = lowpass(dry[c] - low, &state->high[c], 4200.0f, rate_hz);
            wet[c] = saturate(mid * 1.5f + low * 0.4f, 1.0f + 2.0f * amount);
        }
        break;
    case RP_EFFECT_TUBE:
        for (int c = 0; c < RP_CHANNELS; c++) {
            float x = dry[c];
            wet[c] = saturate(x + 0.12f * amount * x * x, 1.0f + 3.0f * amount);
        }
        break;
    case RP_EFFECT_CASSETTE: {
        float wobble = 0.004f + (0.0015f * amount * sinf(state->phase));
        float offset_frames = rate_hz * wobble;
        size_t offset_whole_frames = (size_t)offset_frames;
        float fraction = offset_frames - (float)offset_whole_frames;
        state->phase += 2.0f * RP_PI * 0.7f / rate_hz;
        if (state->phase >= 2.0f * RP_PI) state->phase -= 2.0f * RP_PI;
        l = delay_read(&state->delay, offset_whole_frames, 0) * (1.0f - fraction) +
            delay_read(&state->delay, offset_whole_frames + 1, 0) * fraction;
        r = delay_read(&state->delay, offset_whole_frames, 1) * (1.0f - fraction) +
            delay_read(&state->delay, offset_whole_frames + 1, 1) * fraction;
        delay_write(&state->delay, dry[0], dry[1]);
        wet[0] = saturate(lowpass(l, &state->low[0], 7500.0f - 3500.0f * amount, rate_hz), 1.0f + amount);
        wet[1] = saturate(lowpass(r, &state->low[1], 7500.0f - 3500.0f * amount, rate_hz), 1.0f + amount);
        break;
    }
    case RP_EFFECT_BASS:
        for (int c = 0; c < RP_CHANNELS; c++) {
            float low = lowpass(dry[c], &state->low[c], 160.0f, rate_hz);
            wet[c] = dry[c] + low * (0.5f + 1.5f * amount);
        }
        break;
    case RP_EFFECT_UNDERWATER: {
        float cutoff_hz = 850.0f + 400.0f * sinf(state->phase);
        state->phase += 2.0f * RP_PI * 0.22f / rate_hz;
        if (state->phase >= 2.0f * RP_PI) state->phase -= 2.0f * RP_PI;
        for (int c = 0; c < RP_CHANNELS; c++) wet[c] = lowpass(dry[c], &state->low[c], cutoff_hz, rate_hz);
        break;
    }
    case RP_EFFECT_HALL: {
        l = 0.4f * delay_read(&state->delay, (size_t)(rate_hz * 0.0297f), 0) +
            0.3f * delay_read(&state->delay, (size_t)(rate_hz * 0.0437f), 1) +
            0.2f * delay_read(&state->delay, (size_t)(rate_hz * 0.071f), 0) +
            0.1f * delay_read(&state->delay, (size_t)(rate_hz * 0.113f), 1);
        r = 0.4f * delay_read(&state->delay, (size_t)(rate_hz * 0.0371f), 1) +
            0.3f * delay_read(&state->delay, (size_t)(rate_hz * 0.0531f), 0) +
            0.2f * delay_read(&state->delay, (size_t)(rate_hz * 0.079f), 1) +
            0.1f * delay_read(&state->delay, (size_t)(rate_hz * 0.127f), 0);
        delay_write(&state->delay, dry[0] + r * 0.4f, dry[1] + l * 0.4f);
        wet[0] = dry[0] + l * 0.65f;
        wet[1] = dry[1] + r * 0.65f;
        break;
    }
    case RP_EFFECT_ECHO: {
        size_t offset_frames = (size_t)(rate_hz * 0.32f);
        l = delay_read(&state->delay, offset_frames, 0);
        r = delay_read(&state->delay, offset_frames, 1);
        float feedback = 0.18f + 0.48f * amount;
        delay_write(&state->delay, dry[0] + l * feedback, dry[1] + r * feedback);
        wet[0] = dry[0] + l * 0.6f;
        wet[1] = dry[1] + r * 0.6f;
        break;
    }
    default: break;
    }
    *left = dry[0] + (wet[0] - dry[0]) * amount;
    *right = dry[1] + (wet[1] - dry[1]) * amount;
}

void rp_effects_process(rp_effects *rack, float *interleaved_stereo,
                        unsigned int frame_count, const rp_effect_controls *controls,
                        uint32_t reset_mask) {
    if (!rack || !interleaved_stereo || !controls) return;
    for (int i = 0; i < RP_EFFECT_COUNT; i++) {
        if (reset_mask & (UINT32_C(1) << i)) rack->effects[i].resetting = 1;
    }
    int bypass = controls->bypass;
    if (!bypass && reset_mask == RP_EFFECT_RESET_ALL) rack->bypass_waiting = 1;
    for (unsigned int frame = 0; frame < frame_count; frame++) {
        float *samples = interleaved_stereo + (size_t)frame * RP_CHANNELS;
        float original[RP_CHANNELS] = {samples[0], samples[1]};
        float left = isfinite(original[0]) ? fmaxf(-1.0f, fminf(1.0f, original[0])) : 0;
        float right = isfinite(original[1]) ? fmaxf(-1.0f, fminf(1.0f, original[1])) : 0;
        float dry_left = left, dry_right = right;
        int active = 0;
        rack->bypass_level = approach(rack->bypass_level, (bypass || rack->bypass_waiting) ? 0.0f : 1.0f,
                                      rack->transition_step);
        for (int i = 0; i < RP_EFFECT_COUNT; i++) {
            rp_effect_state *state = &rack->effects[i];
            float target = fminf((float)controls->intensity_percent[i] / 100.0f, 1.0f);
            state->level = approach(state->level, state->resetting ? 0.0f : target, rack->transition_step);
            if (state->resetting && state->level == 0.0f) {
                effect_reset(state);
                state->resetting = 0;
            }
            if (state->level > 0.0f) {
                active = 1;
                process_effect(state, i, state->level, &left, &right, (float)rack->sample_rate_hz);
            }
        }
        if (rack->bypass_waiting) {
            int pending = 0;
            for (int i = 0; i < RP_EFFECT_COUNT; i++) pending |= rack->effects[i].resetting;
            if (!pending && rack->bypass_level == 0.0f) rack->bypass_waiting = 0;
        }
        if (active && rack->bypass_level > 0.0f) {
            left = output_limit(left);
            right = output_limit(right);
            samples[0] = dry_left + (left - dry_left) * rack->bypass_level;
            samples[1] = dry_right + (right - dry_right) * rack->bypass_level;
            if (!isfinite(samples[0])) samples[0] = 0;
            if (!isfinite(samples[1])) samples[1] = 0;
        }
    }
}
