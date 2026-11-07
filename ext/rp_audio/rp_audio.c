/* rp_audio: minimal playback shim over miniaudio.
 * Owns a lock-free SPSC ring buffer of float32 interleaved stereo frames.
 * Producer: Ruby decoder thread via rp_write (FFI, GVL released).
 * Consumer: miniaudio's native callback — never touches Ruby.
 * Module-level state => exactly one device per process.
 */
#define MINIAUDIO_IMPLEMENTATION
#define MA_NO_DECODING
#define MA_NO_ENCODING
#include "miniaudio.h"
#include "ring_cursor.h"
#include "effects.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RP_CHANNELS 2
#define RP_MILLISECONDS_PER_SECOND 1000
#define RP_MIN_RING_BUFFER_FRAMES 1024
#define RP_EFFECT_RESET_BIT UINT64_C(128)
#define RP_EFFECT_VALUE_MASK UINT64_C(127)

static ma_context g_ctx;
static ma_device g_device;
static float *g_rb;                     /* rb_capacity * RP_CHANNELS floats */
static uint64_t g_rb_capacity;          /* frames */
static _Atomic uint64_t g_read;         /* monotonically increasing frame counters */
static _Atomic uint64_t g_write;
static _Atomic int g_paused;
static _Atomic uint64_t g_frames_played;
static _Atomic uint64_t g_effect_controls[RP_EFFECT_COUNT];
static _Atomic uint64_t g_effect_bypass;
static _Atomic uint64_t g_flush_epoch;
static uint64_t g_accepted_controls;
static uint64_t g_accepted_bypass;
static uint64_t g_applied_epoch;
static rp_effects *g_effects;
static int g_initialized = 0;

/* The callback makes at most one CAS attempt; a conflicting update waits for
 * the next device block instead of making the real-time thread spin. */
static uint64_t claim_control(_Atomic uint64_t *mailbox, uint64_t previous,
                              uint32_t *reset_mask, uint32_t reset_bits) {
    uint64_t value = atomic_load(mailbox);
    if (value & RP_EFFECT_RESET_BIT) {
        uint64_t cleared = value & ~RP_EFFECT_RESET_BIT;
#ifdef RP_AUDIO_TEST_HOOKS
        test_before_claim();
#endif
        if (!atomic_compare_exchange_strong(mailbox, &value, cleared)) return previous;
        *reset_mask |= reset_bits;
        return cleared;
    }
    return value;
}

static void publish_control(_Atomic uint64_t *mailbox, uint64_t value, int reset) {
    uint64_t old = atomic_load(mailbox);
    uint64_t desired;
    do {
        desired = value | (old & RP_EFFECT_RESET_BIT) | (reset ? RP_EFFECT_RESET_BIT : 0);
    } while (!atomic_compare_exchange_weak(mailbox, &old, desired));
}

static void data_callback(ma_device *dev, void *output, const void *input, ma_uint32 frame_count) {
    (void)dev; (void)input;
    float *out = (float *)output;
    uint64_t epoch = atomic_load(&g_flush_epoch);
#ifdef RP_AUDIO_TEST_HOOKS
    test_after_epoch();
#endif
    if ((epoch & 1) || atomic_load(&g_paused)) {
        memset(out, 0, (size_t)frame_count * RP_CHANNELS * sizeof(float));
        return;
    }
    uint64_t r = atomic_load(&g_read);
    uint64_t w = atomic_load(&g_write);
    uint64_t avail = rp_ring_buffered(r, w, g_rb_capacity);
    ma_uint32 n = 0;
    n = (ma_uint32)(avail < frame_count ? avail : frame_count);
    for (ma_uint32 i = 0; i < n; i++) {
        uint64_t idx = ((r + i) % g_rb_capacity) * RP_CHANNELS;
        out[i * RP_CHANNELS]     = g_rb[idx];
        out[i * RP_CHANNELS + 1] = g_rb[idx + 1];
    }
#ifdef RP_AUDIO_TEST_HOOKS
    test_after_copy();
#endif
    if (atomic_load(&g_flush_epoch) != epoch) {
        memset(out, 0, (size_t)frame_count * RP_CHANNELS * sizeof(float));
        return;
    }
    if (n) {
        if (g_applied_epoch != epoch) {
            rp_effects_reset(g_effects);
            g_applied_epoch = epoch;
        }
        uint32_t reset_mask = 0;
        for (unsigned int i = 0; i < RP_EFFECT_COUNT; i++) {
            uint64_t previous = (g_accepted_controls >> (7 * i)) & RP_EFFECT_VALUE_MASK;
            uint64_t value = claim_control(&g_effect_controls[i], previous, &reset_mask, 1u << i);
            g_accepted_controls &= ~(RP_EFFECT_VALUE_MASK << (7 * i));
            g_accepted_controls |= (value & RP_EFFECT_VALUE_MASK) << (7 * i);
        }
        g_accepted_bypass = claim_control(&g_effect_bypass, g_accepted_bypass,
                                           &reset_mask, (1u << RP_EFFECT_COUNT) - 1);
#ifdef RP_AUDIO_TEST_HOOKS
        test_before_process();
#endif
        rp_effects_process(g_effects, out, n, g_accepted_controls | (g_accepted_bypass << 56), reset_mask);
    }
    if (n < frame_count)  /* underrun or paused: emit silence */
        memset(out + (size_t)n * RP_CHANNELS, 0,
               ((size_t)frame_count - n) * RP_CHANNELS * sizeof(float));
    /* A concurrent flush may have advanced g_read after our snapshot. CAS
     * prevents this callback from restoring its older cursor afterward. */
    rp_ring_commit_read(&g_read, r, n);
    atomic_fetch_add(&g_frames_played, n);
}

/* sample_rate 0 = device native. use_null != 0 = miniaudio null backend (tests). */
int rp_init(unsigned int sample_rate, unsigned int buffer_ms, int use_null) {
    if (g_initialized) return -1;
    ma_context_config cc = ma_context_config_init();
    if (use_null) {
        ma_backend backends[] = { ma_backend_null };
        if (ma_context_init(backends, 1, &cc, &g_ctx) != MA_SUCCESS) return -2;
    } else {
        if (ma_context_init(NULL, 0, &cc, &g_ctx) != MA_SUCCESS) return -2;
    }
    ma_device_config dc = ma_device_config_init(ma_device_type_playback);
    dc.playback.format   = ma_format_f32;
    dc.playback.channels = RP_CHANNELS;
    dc.sampleRate        = sample_rate;    /* 0 => native */
    dc.dataCallback      = data_callback;
    if (ma_device_init(&g_ctx, &dc, &g_device) != MA_SUCCESS) {
        ma_context_uninit(&g_ctx);
        return -3;
    }
    if (!atomic_is_lock_free(&g_flush_epoch) || !atomic_is_lock_free(&g_effect_bypass) ||
        !atomic_is_lock_free(&g_effect_controls[0]) || !(g_effects = rp_effects_create(g_device.sampleRate))) {
        ma_device_uninit(&g_device); ma_context_uninit(&g_ctx); return -4;
    }
    g_rb_capacity = (uint64_t)g_device.sampleRate * buffer_ms / RP_MILLISECONDS_PER_SECOND;
    if (g_rb_capacity < RP_MIN_RING_BUFFER_FRAMES) g_rb_capacity = RP_MIN_RING_BUFFER_FRAMES;
    g_rb = (float *)calloc((size_t)g_rb_capacity * RP_CHANNELS, sizeof(float));
    if (!g_rb) { rp_effects_destroy(g_effects); g_effects = NULL; ma_device_uninit(&g_device); ma_context_uninit(&g_ctx); return -4; }
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_paused, 0);
    atomic_store(&g_frames_played, 0);
    atomic_store(&g_flush_epoch, 0);
    atomic_store(&g_effect_bypass, 0);
    for (unsigned int i = 0; i < RP_EFFECT_COUNT; i++) atomic_store(&g_effect_controls[i], 0);
    g_accepted_controls = 0;
    g_accepted_bypass = 0;
    g_applied_epoch = 0;
    g_initialized = 1;
    return 0;
}

unsigned int rp_sample_rate(void) { return g_initialized ? g_device.sampleRate : 0; }
int rp_start(void) { return ma_device_start(&g_device) == MA_SUCCESS ? 0 : -1; }
int rp_stop(void)  { return ma_device_stop(&g_device)  == MA_SUCCESS ? 0 : -1; }
void rp_set_paused(int p) { atomic_store(&g_paused, p ? 1 : 0); }

unsigned int rp_writable_frames(void) {
    return (unsigned int)rp_ring_writable(atomic_load(&g_read),
                                          atomic_load(&g_write),
                                          g_rb_capacity);
}

unsigned int rp_buffered_frames(void) {
    return (unsigned int)rp_ring_buffered(atomic_load(&g_read),
                                          atomic_load(&g_write),
                                          g_rb_capacity);
}

/* Copy up to frame_count frames in; returns frames accepted (may be 0 when full). */
unsigned int rp_write(const float *frames, unsigned int frame_count) {
    /* Ruby guards normal lifecycle, but native validation is still required:
     * an FFI caller can invoke this function directly, and a stale Ruby writer
     * must degrade to a short write rather than dereference a freed ring. */
    if (!g_initialized || g_rb == NULL || g_rb_capacity == 0 || frames == NULL || frame_count == 0)
        return 0;
    uint64_t r = atomic_load(&g_read);
    uint64_t w = atomic_load(&g_write);
    uint64_t space = rp_ring_writable(r, w, g_rb_capacity);
    unsigned int n = (unsigned int)(space < frame_count ? space : frame_count);
    for (unsigned int i = 0; i < n; i++) {
        uint64_t idx = ((w + i) % g_rb_capacity) * RP_CHANNELS;
        g_rb[idx]     = frames[i * RP_CHANNELS];
        g_rb[idx + 1] = frames[i * RP_CHANNELS + 1];
    }
    atomic_store(&g_write, w + n);
    return n;
}

unsigned long long rp_frames_played(void) { return atomic_load(&g_frames_played); }

void rp_set_effect(unsigned int id, unsigned int intensity_percent, int reset) {
    if (id >= RP_EFFECT_COUNT) return;
    if (intensity_percent > 100) intensity_percent = 100;
    publish_control(&g_effect_controls[id], intensity_percent, reset);
}

void rp_set_effects_bypass(int bypass, int reset) {
    publish_control(&g_effect_bypass, bypass ? 1 : 0, reset);
}

/* Drop all buffered audio (seek/skip). A callback that already copied samples
 * may still emit that device period, but its CAS cannot undo this cursor. */
void rp_flush(void) {
    uint64_t epoch = atomic_load(&g_flush_epoch);
    if (epoch >= UINT64_MAX - 2) { atomic_store(&g_flush_epoch, UINT64_MAX); return; }
    atomic_store(&g_flush_epoch, epoch + 1);
    atomic_store(&g_read, atomic_load(&g_write));
    atomic_store(&g_flush_epoch, epoch + 2);
}

void rp_free(void) {
    if (!g_initialized) return;
    ma_device_uninit(&g_device);
    ma_context_uninit(&g_ctx);
    rp_effects_destroy(g_effects);
    g_effects = NULL;
    free(g_rb);
    g_rb = NULL;
    g_initialized = 0;
}
