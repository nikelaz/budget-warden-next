#ifndef CATEGORY_H
#define CATEGORY_H

#include "stdint.h" 
#include "bwstring.h"
#include "result.h"

typedef struct {
  int id;
  BWString title;
  uint64_t amount_planned;
  uint64_t amount_actual;
} Category;

result category_init(
  Category *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual
);

void category_free(Category *category);

#endif
