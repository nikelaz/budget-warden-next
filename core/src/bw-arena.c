#include "bw-arena.h"

static uintptr_t align_forward(uintptr_t ptr, size_t align) {
    uintptr_t p = ptr;
    uintptr_t a = (uintptr_t)align;
    uintptr_t modulo = p & (a - 1);

    if (modulo != 0) {
        p += a - modulo;
    }

    return p;
}

BWResult bw_arena_init(BWArena *arena, size_t capacity)
{ 
    if (arena == NULL)
    {
        return BWResult_ERR;
    }
    
    arena->buffer = malloc(capacity);
    arena->capacity = capacity;
    arena->offset = 0;

    if (arena->buffer == NULL)
    {
        return BWResult_ERR;
    }

    return BWResult_OK;
}

void bw_arena_destroy(BWArena *arena) {
    free(arena->buffer);
    arena->buffer = NULL;
    arena->capacity = 0;
    arena->offset = 0;
}

void bw_arena_reset(BWArena *arena) {
    arena->offset = 0;
}

void *bw_arena_alloc_aligned(BWArena *arena, size_t size, size_t align) {
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
