#ifndef BW_ARENA_H
#define BW_ARENA_H

#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>
#include "bw-result.h"

typedef struct {
  unsigned char *buffer;
  size_t capacity;
  size_t offset;
} BWArena;

BWResult bw_arena_init(BWArena *arena, size_t capacity);
void bw_arena_destroy(BWArena *arena);
void bw_arena_reset(BWArena *arena);
void *bw_arena_alloc_aligned(BWArena *arena, size_t size, size_t align);

#define bw_arena_alloc(arena, type, count) \
    (type *)bw_arena_alloc_aligned((arena), sizeof(type) * (count), _Alignof(type))

#endif
