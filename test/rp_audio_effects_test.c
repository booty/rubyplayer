#include "effects.h"
#include <assert.h>
#include <stdint.h>
#include <math.h>
#include <stdlib.h>
#include <float.h>
#include <string.h>

static rp_effect_controls controls_with(unsigned int effect, uint8_t intensity_percent) {
    rp_effect_controls controls = {0};
    controls.intensity_percent[effect] = intensity_percent;
    return controls;
}

static rp_effect_controls bypassed(rp_effect_controls controls) {
    controls.bypass = 1;
    return controls;
}

static const rp_effect_controls NO_EFFECTS = {0};
static const rp_effect_controls BYPASS_ONLY = {.bypass = 1};

static void check_clean(unsigned int rate_hz) {
    rp_effects *rack = rp_effects_create(rate_hz);
    assert(rack != NULL);
    float pcm[] = { -0.0f, 0.25f, -0.5f, 1.0f, 0.125f, -0.75f };
    float original[6];
    memcpy(original, pcm, sizeof(pcm));
    rp_effects_process(rack, pcm, 3, &NO_EFFECTS, 0);
    assert(memcmp(original, pcm, sizeof(pcm)) == 0);
    rp_effects_process(rack, pcm, 0, &BYPASS_ONLY, 0);
    assert(memcmp(original, pcm, sizeof(pcm)) == 0);
    rp_effects_destroy(rack);
}

static void check_each_effect_changes_audio(unsigned int rate_hz) {
    const unsigned int frames = rate_hz;
    float *pcm = malloc((size_t)frames * 2 * sizeof(float));
    assert(pcm != NULL);
    for (unsigned int effect = 0; effect < RP_EFFECT_COUNT; effect++) {
        rp_effects *rack = rp_effects_create(rate_hz);
        assert(rack != NULL);
        for (unsigned int i = 0; i < frames; i++) {
            float sample = 0.3f * sinf(6.2831853f * 440.0f * (float)i / (float)rate_hz);
            pcm[i * 2] = sample;
            pcm[i * 2 + 1] = sample;
        }
        rp_effect_controls single_effect = controls_with(effect, 80);
        rp_effects_process(rack, pcm, frames, &single_effect, 0);
        double difference = 0;
        for (unsigned int i = rate_hz / 2; i < frames; i++) {
            float original = 0.3f * sinf(6.2831853f * 440.0f * (float)i / (float)rate_hz);
            assert(isfinite(pcm[i * 2]));
            difference += fabsf(pcm[i * 2] - original);
        }
        assert(difference > 1.0);
        rp_effects_destroy(rack);
    }
    free(pcm);
}

static void check_echo_and_reset(unsigned int rate_hz) {
    rp_effects *rack = rp_effects_create(rate_hz);
    const unsigned int frames = rate_hz;
    float *pcm = calloc((size_t)frames * 2, sizeof(float));
    rp_effect_controls echo = controls_with(RP_EFFECT_ECHO, 100);
    assert(rack && pcm);
    rp_effects_process(rack, pcm, rate_hz / 10, &echo, 0);
    pcm[0] = 0.5f;
    rp_effects_process(rack, pcm, frames, &echo, 0);
    unsigned int repeat = (unsigned int)(rate_hz * 0.32f);
    assert(pcm[repeat * 2] > 0.1f);
    assert(pcm[repeat * 4] > 0.02f);

    rp_effects_reset(rack);
    memset(pcm, 0, (size_t)frames * 2 * sizeof(float));
    pcm[0] = 0.5f;
    rp_effects_process(rack, pcm, rate_hz / 10, &echo, 0);
    memset(pcm, 0, (size_t)frames * 2 * sizeof(float));
    /* Off/on before the next block still invalidates the old delayed impulse. */
    rp_effects_process(rack, pcm, frames, &echo, UINT32_C(1) << RP_EFFECT_ECHO);
    for (unsigned int i = 0; i < frames * 2; i++) assert(pcm[i] == 0.0f);

    rp_effects_reset(rack);
    memset(pcm, 0, (size_t)frames * 2 * sizeof(float));
    rp_effects_process(rack, pcm, frames, &echo, 0);
    for (unsigned int i = 0; i < frames * 2; i++) assert(pcm[i] == 0.0f);
    free(pcm);
    rp_effects_destroy(rack);
}

static void check_bypass_and_extremes(void) {
    const unsigned int frames = 48000;
    rp_effects *rack = rp_effects_create(frames);
    float *pcm = calloc((size_t)frames * 2, sizeof(float));
    assert(rack && pcm);
    rp_effect_controls controls = {0};
    for (unsigned int i = 0; i < RP_EFFECT_COUNT; i++) controls.intensity_percent[i] = 100;
    rp_effect_controls bypassed_controls = bypassed(controls);
    for (unsigned int i = 0; i < frames * 2; i++) pcm[i] = i % 2 ? -FLT_MAX : FLT_MAX;
    pcm[0] = INFINITY;
    pcm[1] = NAN;
    rp_effects_process(rack, pcm, frames, &controls, 0);
    for (unsigned int i = 0; i < frames * 2; i++) {
        assert(isfinite(pcm[i]));
        assert(pcm[i] >= -1.0f && pcm[i] <= 1.0f);
    }
    for (unsigned int i = 0; i < frames; i++) {
        pcm[i * 2] = pcm[i * 2 + 1] = 0.2f * sinf(6.2831853f * 440.0f * (float)i / 48000.0f);
    }
    rp_effects_process(rack, pcm, frames, &controls, 0);
    double recovered = 0;
    for (unsigned int i = frames; i < frames * 2; i++) recovered += fabsf(pcm[i]);
    assert(recovered > 1.0);
    for (unsigned int i = 0; i < frames * 2; i++) pcm[i] = i % 2 ? -0.25f : 0.25f;
    rp_effects_process(rack, pcm, frames, &bypassed_controls, 0);
    for (unsigned int i = frames; i < frames * 2; i++) assert(pcm[i] == (i % 2 ? -0.25f : 0.25f));
    free(pcm);
    rp_effects_destroy(rack);
}

static void check_bypass_does_not_release_hidden_echo(void) {
    rp_effects *rack = rp_effects_create(48000);
    float pcm[480 * 2] = {0};
    rp_effect_controls echo = controls_with(RP_EFFECT_ECHO, 100);
    rp_effect_controls hidden_echo = bypassed(echo);
    assert(rack);
    for (int i = 0; i < 5; i++) rp_effects_process(rack, pcm, 480, &hidden_echo, 0);
    pcm[0] = 0.5f;
    rp_effects_process(rack, pcm, 1, &hidden_echo, 0);
    memset(pcm, 0, sizeof(pcm));
    for (int i = 0; i < 31; i++) rp_effects_process(rack, pcm, 480, &hidden_echo, 0);
    rp_effects_process(rack, pcm, 239, &hidden_echo, 0);
    rp_effects_process(rack, pcm, 480, &echo, RP_EFFECT_RESET_ALL);
    for (int i = 0; i < 960; i++) assert(fabsf(pcm[i]) < 0.000001f);
    rp_effects_destroy(rack);
}

static void check_bass_does_not_flatten_peaks(void) {
    const unsigned int frames = 48000;
    rp_effects *rack = rp_effects_create(frames);
    float *pcm = calloc((size_t)frames * 2, sizeof(float));
    assert(rack && pcm);
    for (unsigned int i = 0; i < frames; i++) {
        pcm[i * 2] = pcm[i * 2 + 1] = 0.85f * sinf(6.2831853f * 100.0f * i / frames);
    }
    rp_effect_controls single_effect = controls_with(RP_EFFECT_BASS, 100);
    rp_effects_process(rack, pcm, frames, &single_effect, 0);
    unsigned int clipped_frames = 0;
    for (unsigned int i = frames / 2; i < frames; i++) {
        assert(fabsf(pcm[i * 2]) <= 1.0f);
        if (fabsf(pcm[i * 2]) == 1.0f) clipped_frames++;
    }
    assert(clipped_frames == 0);
    free(pcm);
    rp_effects_destroy(rack);
}

static void check_cassette_wobble_is_continuous(void) {
    const unsigned int rate_hz = 48000, frames = rate_hz * 4;
    rp_effects *rack = rp_effects_create(rate_hz);
    float *pcm = calloc((size_t)frames * 2, sizeof(float));
    assert(rack && pcm);
    for (unsigned int i = 0; i < frames; i++) {
        pcm[i * 2] = pcm[i * 2 + 1] = 0.25f * sinf(6.2831853f * 7000.0f * i / rate_hz);
    }
    rp_effect_controls single_effect = controls_with(RP_EFFECT_CASSETTE, 100);
    rp_effects_process(rack, pcm, frames, &single_effect, 0);
    for (unsigned int i = rate_hz; i < frames; i++) {
        assert(fabsf(pcm[i * 2] - pcm[(i - 1) * 2]) < 0.26f);
    }
    free(pcm);
    rp_effects_destroy(rack);
}

static void check_hall_gives_mono_input_stereo_space(void) {
    const unsigned int rate_hz = 48000, frames = rate_hz;
    rp_effects *rack = rp_effects_create(rate_hz);
    float *pcm = calloc((size_t)frames * 2, sizeof(float));
    assert(rack && pcm);
    rp_effect_controls hall = controls_with(RP_EFFECT_HALL, 100);
    rp_effects_process(rack, pcm, rate_hz / 10, &hall, 0);
    pcm[0] = pcm[1] = 0.5f;
    rp_effects_process(rack, pcm, frames, &hall, 0);
    double difference = 0;
    for (unsigned int i = 1; i < frames; i++) difference += fabsf(pcm[i * 2] - pcm[i * 2 + 1]);
    assert(difference > 0.1);
    free(pcm);
    rp_effects_destroy(rack);
}

static double effect_rms(unsigned int rate_hz, unsigned int effect, float frequency_hz) {
    rp_effects *rack = rp_effects_create(rate_hz);
    float *pcm = malloc((size_t)rate_hz * 2 * sizeof(float));
    assert(rack && pcm);
    for (unsigned int i = 0; i < rate_hz; i++) {
        pcm[i * 2] = pcm[i * 2 + 1] = 0.1f * sinf(6.2831853f * frequency_hz * i / rate_hz);
    }
    rp_effect_controls single_effect = controls_with(effect, 100);
    rp_effects_process(rack, pcm, rate_hz, &single_effect, 0);
    double sum = 0;
    for (unsigned int i = rate_hz / 2; i < rate_hz; i++) sum += pcm[i * 2] * pcm[i * 2];
    free(pcm);
    rp_effects_destroy(rack);
    return sqrt(sum / (rate_hz / 2));
}

static void check_frequency_character(unsigned int rate_hz) {
    double radio_mid = effect_rms(rate_hz, RP_EFFECT_AM_RADIO, 1000.0f);
    assert(radio_mid > effect_rms(rate_hz, RP_EFFECT_AM_RADIO, 100.0f) * 2);
    assert(radio_mid > effect_rms(rate_hz, RP_EFFECT_AM_RADIO, 9000.0f) * 1.3);
    double bass = effect_rms(rate_hz, RP_EFFECT_BASS, 80.0f);
    assert(bass > effect_rms(rate_hz, RP_EFFECT_BASS, 1000.0f) * 1.5);
}

static void check_tube_adds_harmonics(unsigned int rate_hz) {
    rp_effects *rack = rp_effects_create(rate_hz);
    float *pcm = malloc((size_t)rate_hz * 2 * sizeof(float));
    assert(rack && pcm);
    for (unsigned int i = 0; i < rate_hz; i++) {
        pcm[i * 2] = pcm[i * 2 + 1] = 0.5f * sinf(6.2831853f * 400.0f * i / rate_hz);
    }
    rp_effect_controls single_effect = controls_with(RP_EFFECT_TUBE, 100);
    rp_effects_process(rack, pcm, rate_hz, &single_effect, 0);
    double third_harmonic = 0;
    for (unsigned int i = rate_hz / 2; i < rate_hz; i++) {
        third_harmonic += pcm[i * 2] * sinf(6.2831853f * 1200.0f * i / rate_hz);
    }
    assert(fabs(third_harmonic) / (rate_hz / 2) > 0.01);
    free(pcm);
    rp_effects_destroy(rack);
}

int main(void) {
    check_clean(44100);
    check_clean(48000);
    check_each_effect_changes_audio(44100);
    check_each_effect_changes_audio(48000);
    check_echo_and_reset(44100);
    check_echo_and_reset(48000);
    check_bypass_and_extremes();
    check_bypass_does_not_release_hidden_echo();
    check_bass_does_not_flatten_peaks();
    check_cassette_wobble_is_continuous();
    check_hall_gives_mono_input_stereo_space();
    check_frequency_character(44100);
    check_frequency_character(48000);
    check_tube_adds_harmonics(44100);
    check_tube_adds_harmonics(48000);
    return 0;
}
