#ifndef RP_RING_CURSOR_H
#define RP_RING_CURSOR_H

#include <stdatomic.h>
#include <stdint.h>

/* Commit only when no flush changed the cursor after callback snapshot. */
static inline int rp_ring_commit_read(_Atomic uint64_t *cursor,
                                      uint64_t expected,
                                      uint64_t consumed) {
    uint64_t desired = expected + consumed;
    return atomic_compare_exchange_strong(cursor, &expected, desired);
}

/* Cursor corruption must never become unsigned underflow and fake free space. */
static inline uint64_t rp_ring_buffered(uint64_t read,
                                        uint64_t write,
                                        uint64_t capacity) {
    if (write <= read) return 0;
    uint64_t buffered = write - read;
    return buffered < capacity ? buffered : capacity;
}

static inline uint64_t rp_ring_writable(uint64_t read,
                                        uint64_t write,
                                        uint64_t capacity) {
    return capacity - rp_ring_buffered(read, write, capacity);
}

#endif
