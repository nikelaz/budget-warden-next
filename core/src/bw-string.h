/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

#ifndef BW_STRING_H
#define BW_STRING_H

#include <stdlib.h>
#include "bw-arena.h"

typedef struct {
    char *data;
    size_t length;
    size_t capacity;
    BWArena *arena;
} BWString;

int bw_string_init(BWString *s, BWArena *arena);
int bw_string_append(BWString *s, const char *text);
int bw_string_append_len(BWString *s, const char *text, size_t text_len);
void bw_string_clear(BWString *s);

#endif
