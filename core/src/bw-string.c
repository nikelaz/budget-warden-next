#include <stdio.h>
#include <string.h>
#include "bw-string.h"
#include "bw-result.h"

#define BW_STRING_INITIAL_CAPACITY 16

BWResult bw_string_init(BWString *s, BWArena *arena)
{
    if (s == NULL || arena == NULL)
    {
      return BWResult_ERR;
    }

    s->capacity = BW_STRING_INITIAL_CAPACITY;
    s->length = 0;
    s->arena = arena;

    s->data = bw_arena_alloc(arena, char, s->capacity);

    if (s->data == NULL) {
        return BWResult_ERR;
    }

    s->data[0] = '\0';

    return BWResult_OK;
}

BWResult bw_string_append(BWString *s, const char *text)
{
    if (s == NULL || text == NULL)
    {
        return BWResult_ERR;
    }

    size_t text_len = strlen(text);

    return bw_string_append_len(s, text, text_len);
}

static BWResult bw_string_reserve(BWString *s, size_t required)
{
    if (s == NULL || s->arena == NULL) {
        return BWResult_ERR;
    }

    if (required <= s->capacity) {
        return BWResult_OK;
    }

    size_t new_capacity = s->capacity;

    if (new_capacity == 0) {
        new_capacity = BW_STRING_INITIAL_CAPACITY;
    }

    while (new_capacity < required) {
        new_capacity *= 2;
    }

    char *new_data = bw_arena_alloc(s->arena, char, new_capacity);

    if (new_data == NULL) {
        return BWResult_ERR;
    }

    if (s->data != NULL && s->length > 0) {
        memcpy(new_data, s->data, s->length);
    }

    new_data[s->length] = '\0';

    s->data = new_data;
    s->capacity = new_capacity;

    return BWResult_OK;
}

void bw_string_clear(BWString *s)
{
    if (s == NULL)
    {
        return;
    }

    s->data = NULL;
    s->length = 0;
    s->capacity = 0;
    s->arena = NULL;
}

BWResult bw_string_append_len(BWString *s, const char *text, size_t text_len)
{
    if (s == NULL || text == NULL)
    {
        return BWResult_ERR;
    }

    size_t required = s->length + text_len + 1;

    if (bw_string_reserve(s, required) != BWResult_OK)
    {
        return BWResult_ERR;
    }

    memcpy(s->data + s->length, text, text_len);

    s->length += text_len;
    s->data[s->length] = '\0';

    return BWResult_OK;
}
