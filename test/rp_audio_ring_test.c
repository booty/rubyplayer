#include <stdatomic.h>
#include <stdint.h>
#include "ring_cursor.h"

int main(void) {
    _Atomic uint64_t read_cursor;

    atomic_store(&read_cursor, 4);
    if (!rp_ring_commit_read(&read_cursor, 4, 2)) return 1;
    if (atomic_load(&read_cursor) != 6) return 2;

    /* Simulate rp_flush advancing past a callback's stale snapshot. */
    atomic_store(&read_cursor, 12);
    if (rp_ring_commit_read(&read_cursor, 4, 2)) return 3;
    if (atomic_load(&read_cursor) != 12) return 4;

    if (rp_ring_buffered(20, 10, 8) != 0) return 5;
    if (rp_ring_writable(20, 10, 8) != 8) return 6;
    if (rp_ring_buffered(0, 20, 8) != 8) return 7;
    if (rp_ring_writable(0, 20, 8) != 0) return 8;

    return 0;
}
