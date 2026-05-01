#ifndef CATEGORY_H
#define CATEGORY_H

#include "stdint.h" 
#include <stdlib.h>
#include "bwstring.h"
#include "result.h"
#include "transaction.h"
#include "cjson.h"

typedef enum {
    CATEGORY_INCOME,
    CATEGORY_EXPENSES,
    CATEGORY_SAVINGS,
    CATEGORY_DEBT
} CategoryType;

typedef struct {
  int id;
  BWString title;
  uint64_t amount_planned;
  uint64_t amount_actual;
  uint64_t amount_accumulated;
  CategoryType category_type;
  TransactionArray transactions;
} Category;

result category_init(
  Category *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  CategoryType category_type
);

void category_free(Category *category);
cJSON *category_to_json(Category *category);
result category_from_json(Category *category, cJSON *json);
result category_add_transaction(Category *category, Transaction transaction);
result category_remove_transaction(Category *category, Transaction *transaction);

typedef struct {
  Category *items;
  size_t length;
  size_t capacity;
} CategoryArray;

result category_array_init(CategoryArray *array);
result category_array_push_move(CategoryArray *array, Category category);
void category_array_free(CategoryArray *array);

#endif
