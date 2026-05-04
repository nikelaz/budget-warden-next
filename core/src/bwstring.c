#include <stdio.h>
#include <string.h>
#include "bwstring.h"
#include "result.h"

result bw_string_init(BWString *s)
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

result bw_string_append(BWString *s, const char *text)
{
    size_t text_len = strlen(text);

    return bw_string_append_len(s, text, text_len);
}

result bw_string_append_len(BWString *s, const char *text, size_t text_len)
{
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

    memcpy(s->data + s->length, text, text_len);
    s->length += text_len;
    s->data[s->length] = '\0';

    return ok;
}

void bw_string_free(BWString *s)
{
    free(s->data);
    s->data = NULL;
    s->length = 0;
    s->capacity = 0;
}
