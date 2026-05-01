#ifndef BWSTRING_H
#define BWSTRING_H

#include <stdlib.h>

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
} BWString;

int bw_string_init(BWString *s);
int bw_string_append(BWString *s, const char *text);
void bw_string_free(BWString *s);

#endif
