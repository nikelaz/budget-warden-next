#include <stdio.h>
#include <string.h>
#include "dynamic_string.h"
#include "result.h"

result string_init(String *s)
{
    s->capacity = 16;
    s->length = 0;
    s->data = malloc(s->capacity);

    if (s->data == NULL) {
        return err;
    }

    s->data[0] = '\0';
    return ok;
}

result string_append(String *s, const char *text)
{
    size_t text_len = strlen(text);
    size_t required = s->length + text_len + 1;

    if (required > s->capacity) {
        size_t new_capacity = s->capacity;

        while (new_capacity < required) {
            new_capacity *= 2;
        }

        char *new_data = realloc(s->data, new_capacity);

        if (new_data == NULL) {
            return err;
        }

        s->data = new_data;
        s->capacity = new_capacity;
    }

    memcpy(s->data + s->length, text, text_len + 1);
    s->length += text_len;

    return ok;
}

void string_free(String *s)
{
    free(s->data);
    s->data = NULL;
    s->length = 0;
    s->capacity = 0;
}
