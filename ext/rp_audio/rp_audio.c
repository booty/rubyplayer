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
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define RP_CHANNELS 2

static ma_context g_ctx;
static ma_device g_device;
static float *g_rb;                     /* rb_capacity * RP_CHANNELS floats */
static uint64_t g_rb_capacity;          /* frames */
static _Atomic uint64_t g_read;         /* monotonically increasing frame counters */
static _Atomic uint64_t g_write;
static _Atomic int g_paused;
static _Atomic uint64_t g_frames_played;
static int g_initialized = 0;

static void data_callback(ma_device *dev, void *output, const void *input, ma_uint32 frame_count) {
    (void)dev; (void)input;
    float *out = (float *)output;
    uint64_t r = atomic_load(&g_read);
    uint64_t w = atomic_load(&g_write);
    uint64_t avail = rp_ring_buffered(r, w, g_rb_capacity);
    ma_uint32 n = 0;
    if (!atomic_load(&g_paused))
        n = (ma_uint32)(avail < frame_count ? avail : frame_count);
    for (ma_uint32 i = 0; i < n; i++) {
        uint64_t idx = ((r + i) % g_rb_capacity) * RP_CHANNELS;
        out[i * RP_CHANNELS]     = g_rb[idx];
        out[i * RP_CHANNELS + 1] = g_rb[idx + 1];
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
    g_rb_capacity = (uint64_t)g_device.sampleRate * buffer_ms / 1000;
    if (g_rb_capacity < 1024) g_rb_capacity = 1024;
    g_rb = (float *)calloc((size_t)g_rb_capacity * RP_CHANNELS, sizeof(float));
    if (!g_rb) { ma_device_uninit(&g_device); ma_context_uninit(&g_ctx); return -4; }
    atomic_store(&g_read, 0);
    atomic_store(&g_write, 0);
    atomic_store(&g_paused, 0);
    atomic_store(&g_frames_played, 0);
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

/* Drop all buffered audio (seek/skip). A callback that already copied samples
 * may still emit that device period, but its CAS cannot undo this cursor. */
void rp_flush(void) { atomic_store(&g_read, atomic_load(&g_write)); }

void rp_free(void) {
    if (!g_initialized) return;
    ma_device_uninit(&g_device);
    ma_context_uninit(&g_ctx);
    free(g_rb);
    g_rb = NULL;
    g_initialized = 0;
}
