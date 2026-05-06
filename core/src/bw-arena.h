#ifndef ARENA_H
#define ARENA_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

typedef struct {
  unsigned char *buffer;
  size_t capacity;
  size_t offset;
} BWArena;

static inline uintptr_t align_forward(uintptr_t ptr, size_t align) {
    uintptr_t p = ptr;
    uintptr_t a = (uintptr_t)align;
    uintptr_t modulo = p & (a - 1);

    if (modulo != 0) {
        p += a - modulo;
    }

    return p;
}

static inline BWArena arena_create(size_t capacity) {
    BWArena arena;
    arena.buffer = malloc(capacity);
    arena.capacity = capacity;
    arena.offset = 0;

    assert(arena.buffer != NULL);

    return arena;
}

static inline void arena_destroy(BWArena *arena) {
    free(arena->buffer);
    arena->buffer = NULL;
    arena->capacity = 0;
    arena->offset = 0;
}

static inline void arena_reset(BWArena *arena) {
    arena->offset = 0;
}

static inline void *arena_alloc_aligned(BWArena *arena, size_t size, size_t align) {
    uintptr_t base = (uintptr_t)arena->buffer;
    uintptr_t current = base + arena->offset;
    uintptr_t aligned = align_forward(current, align);

    size_t padding = aligned - current;
    size_t new_offset = arena->offset + padding + size;

    if (new_offset > arena->capacity) {
        return NULL;
    }

    void *result = (void *)aligned;
    arena->offset = new_offset;

    memset(result, 0, size);
    return result;
}

#define arena_alloc(arena, type, count) \
    (type *)arena_alloc_aligned((arena), sizeof(type) * (count), _Alignof(type))

#endif
