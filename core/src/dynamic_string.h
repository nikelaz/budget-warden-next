#ifndef DYNAMIC_STRING_H
#define DYNAMIC_STRING_H

#include <stdlib.h>

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} String;

int string_init(String *s);
int string_append(String *s, const char *text);
void string_free(String *s);

#endif
