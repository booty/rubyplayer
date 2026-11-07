#define RP_AUDIO_TEST_HOOKS 1
static void test_after_epoch(void);
static void test_after_copy(void);
static void test_before_claim(void);
static void test_before_process(void);
#include "../ext/rp_audio/rp_audio.c"
#include <assert.h>

static int hook_mode;
static _Atomic uint64_t *claim_hook_mailbox;

static void replace_source(void) {
    rp_flush();
    float next[] = {0.75f, -0.75f};
    assert(rp_write(next, 1) == 1);
}

static void test_after_epoch(void) {
    if (hook_mode == 1) { hook_mode = 0; replace_source(); }
}

static void test_after_copy(void) {
    if (hook_mode == 2) { hook_mode = 0; replace_source(); }
}

static void test_before_claim(void) {
    if (claim_hook_mailbox) {
        publish_control(claim_hook_mailbox, 70, 0);
        claim_hook_mailbox = NULL;
    }
}

static void test_before_process(void) {
    if (hook_mode == 3) { hook_mode = 0; replace_source(); }
}

static void test_control_claim_conflict(void) {
    _Atomic uint64_t mailbox = RP_EFFECT_RESET_BIT;
    uint32_t resets = 0;
    claim_hook_mailbox = &mailbox;
    assert(claim_control(&mailbox, 50, &resets, 1) == 50);
    assert(resets == 0);
    assert(claim_control(&mailbox, 50, &resets, 1) == 70);
    assert(resets == 1);
}

static void test_interleaving(int mode) {
    g_rb_capacity = 16;
    g_rb = calloc(g_rb_capacity * 2, sizeof(float));
    g_effects = rp_effects_create(48000);
    g_initialized = 1;
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_paused, 0);
    atomic_store(&g_flush_epoch, 0);
    atomic_store(&g_frames_played, 0);
    g_applied_epoch = 0;
    float old[] = {0.25f, -0.25f};
    assert(rp_write(old, 1) == 1);
    hook_mode = mode;
    float out[2] = {9, 9};
    data_callback(NULL, out, NULL, 1);
    assert(out[0] == 0 && out[1] == 0);
    assert(rp_frames_played() == 0);
    data_callback(NULL, out, NULL, 1);
    assert(out[0] == 0.75f && out[1] == -0.75f);
    assert(rp_frames_played() == 1);
    free(g_rb);
    rp_effects_destroy(g_effects);
    g_rb = NULL;
    g_effects = NULL;
    g_initialized = 0;
}

static void test_pause_and_underrun(void) {
    g_rb_capacity = 16;
    g_rb = calloc(g_rb_capacity * 2, sizeof(float));
    g_effects = rp_effects_create(48000);
    g_initialized = 1;
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_flush_epoch, 0);
    atomic_store(&g_frames_played, 0);
    g_applied_epoch = 0;
    float input[] = {0.5f, -0.5f};
    assert(rp_write(input, 1) == 1);
    float out[6] = {9, 9, 9, 9, 9, 9};
    atomic_store(&g_paused, 1);
    data_callback(NULL, out, NULL, 3);
    for (int i = 0; i < 6; i++) assert(out[i] == 0);
    assert(rp_frames_played() == 0);
    atomic_store(&g_paused, 0);
    data_callback(NULL, out, NULL, 3);
    assert(out[0] == 0.5f && out[1] == -0.5f);
    for (int i = 2; i < 6; i++) assert(out[i] == 0);
    assert(rp_frames_played() == 1);
    free(g_rb);
    rp_effects_destroy(g_effects);
    g_rb = NULL;
    g_effects = NULL;
    g_initialized = 0;
}

static void test_flush_after_final_check_preserves_next_source(void) {
    g_rb_capacity = 16;
    g_rb = calloc(g_rb_capacity * 2, sizeof(float));
    g_effects = rp_effects_create(48000);
    g_initialized = 1;
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_flush_epoch, 0);
    atomic_store(&g_frames_played, 0);
    g_applied_epoch = 0;
    float input[] = {0.25f, -0.25f};
    assert(rp_write(input, 1) == 1);
    float out[2] = {0, 0};
    hook_mode = 3;
    data_callback(NULL, out, NULL, 1);
    assert(out[0] == 0.25f && out[1] == -0.25f);
    data_callback(NULL, out, NULL, 1);
    assert(out[0] == 0.75f && out[1] == -0.75f);
    assert(rp_frames_played() == 2);
    free(g_rb);
    rp_effects_destroy(g_effects);
    g_rb = NULL;
    g_effects = NULL;
    g_initialized = 0;
}

static void test_flush_discards_callback_echo(void) {
    g_rb_capacity = 20000;
    g_rb = calloc(g_rb_capacity * 2, sizeof(float));
    g_effects = rp_effects_create(48000);
    g_initialized = 1;
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_flush_epoch, 0);
    atomic_store(&g_frames_played, 0);
    g_applied_epoch = 0;
    memset(&g_accepted_controls, 0, sizeof(g_accepted_controls));
    for (int i = 0; i < RP_EFFECT_COUNT; i++) atomic_store(&g_effect_controls[i], 0);
    atomic_store(&g_effect_bypass, 0);
    rp_set_effect(RP_EFFECT_ECHO, 100, 0);
    float *pcm = calloc(g_rb_capacity * 2, sizeof(float));
    assert(rp_write(pcm, 4800) == 4800);
    data_callback(NULL, pcm, NULL, 4800);
    pcm[0] = 0.5f;
    assert(rp_write(pcm, 1) == 1);
    data_callback(NULL, pcm, NULL, 1);
    rp_flush();
    memset(pcm, 0, g_rb_capacity * 2 * sizeof(float));
    assert(rp_write(pcm, 16000) == 16000);
    data_callback(NULL, pcm, NULL, 16000);
    for (int i = 0; i < 32000; i++) assert(pcm[i] == 0.0f);
    free(pcm);
    free(g_rb);
    rp_effects_destroy(g_effects);
    g_rb = NULL;
    g_effects = NULL;
    g_initialized = 0;
}

int main(void) {
    test_control_claim_conflict();
    test_interleaving(1);
    test_interleaving(2);
    test_pause_and_underrun();
    test_flush_after_final_check_preserves_next_source();
    test_flush_discards_callback_echo();
    return 0;
}
