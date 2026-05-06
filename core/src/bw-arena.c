#include "bw-arena.h"

#define BW_ARENA_GROWTH_CHUNK (1024 * 1024)

static uintptr_t align_forward(uintptr_t ptr, size_t align)
{
  uintptr_t p = ptr;
  uintptr_t a = (uintptr_t)align;
  uintptr_t modulo = p & (a - 1);

  if (modulo != 0)
  {
    p += a - modulo;
  }

  return p;
}

static size_t block_capacity_for(size_t required)
{
  size_t capacity = BW_ARENA_GROWTH_CHUNK;

  while (capacity < required)
  {
    if (SIZE_MAX - capacity < BW_ARENA_GROWTH_CHUNK)
    {
      return required;
    }

    capacity += BW_ARENA_GROWTH_CHUNK;
  }

  return capacity;
}

static BWArenaBlock *bw_arena_block_create(size_t capacity)
{
  BWArenaBlock *block = malloc(sizeof(BWArenaBlock));

  if (block == NULL)
  {
    return NULL;
  }

  block->buffer = malloc(capacity);

  if (block->buffer == NULL)
  {
    free(block);
    return NULL;
  }

  block->capacity = capacity;
  block->offset = 0;
  block->next = NULL;
  return block;
}

static void bw_arena_sync_current(BWArena *arena)
{
  if (arena == NULL || arena->current == NULL)
  {
    return;
  }

  arena->buffer = arena->current->buffer;
  arena->capacity = arena->current->capacity;
  arena->offset = arena->current->offset;
}

static void bw_arena_block_destroy(BWArenaBlock *block)
{
  if (block == NULL)
  {
    return;
  }

  free(block->buffer);
  free(block);
}

static void bw_arena_destroy_extra_blocks(BWArena *arena)
{
  if (arena == NULL || arena->first == NULL)
  {
    return;
  }

  BWArenaBlock *block = arena->first->next;

  while (block != NULL)
  {
    BWArenaBlock *next = block->next;
    bw_arena_block_destroy(block);
    block = next;
  }

  arena->first->next = NULL;
}

static BWArenaBlock *bw_arena_append_block(BWArena *arena, size_t required)
{
  size_t capacity = block_capacity_for(required);
  BWArenaBlock *block = bw_arena_block_create(capacity);

  if (block == NULL)
  {
    return NULL;
  }

  arena->current->next = block;
  arena->current = block;
  bw_arena_sync_current(arena);
  return block;
}

BWResult bw_arena_init(BWArena *arena, size_t capacity)
{
  if (arena == NULL || capacity == 0)
  {
    return BWResult_ERR;
  }

  BWArenaBlock *block = bw_arena_block_create(capacity);

  if (block == NULL)
  {
    return BWResult_ERR;
  }

  arena->first = block;
  arena->current = block;
  bw_arena_sync_current(arena);
  return BWResult_OK;
}

void bw_arena_destroy(BWArena *arena)
{
  if (arena == NULL)
  {
    return;
  }

  BWArenaBlock *block = arena->first;

  while (block != NULL)
  {
    BWArenaBlock *next = block->next;
    bw_arena_block_destroy(block);
    block = next;
  }

  arena->buffer = NULL;
  arena->capacity = 0;
  arena->offset = 0;
  arena->first = NULL;
  arena->current = NULL;
}

void bw_arena_reset(BWArena *arena)
{
  if (arena == NULL || arena->first == NULL)
  {
    return;
  }

  bw_arena_destroy_extra_blocks(arena);
  arena->first->offset = 0;
  arena->current = arena->first;
  bw_arena_sync_current(arena);
}

void *bw_arena_alloc_aligned(BWArena *arena, size_t size, size_t align)
{
  if (arena == NULL || arena->current == NULL || align == 0)
  {
    return NULL;
  }

  BWArenaBlock *block = arena->current;
  uintptr_t base = (uintptr_t)block->buffer;
  uintptr_t current = base + block->offset;
  uintptr_t aligned = align_forward(current, align);
  size_t padding = aligned - current;

  if (size > SIZE_MAX - block->offset - padding)
  {
    return NULL;
  }

  size_t new_offset = block->offset + padding + size;

  if (new_offset > block->capacity)
  {
    size_t required = size + align;

    if (required < size)
    {
      return NULL;
    }

    block = bw_arena_append_block(arena, required);

    if (block == NULL)
    {
      return NULL;
    }

    base = (uintptr_t)block->buffer;
    current = base + block->offset;
    aligned = align_forward(current, align);
    padding = aligned - current;
    new_offset = block->offset + padding + size;

    if (new_offset > block->capacity)
    {
      return NULL;
    }
  }

  void *result = (void *)aligned;
  block->offset = new_offset;
  bw_arena_sync_current(arena);

  memset(result, 0, size);
  return result;
}
