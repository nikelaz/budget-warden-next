#ifndef BW_CATEGORY_H
#define BW_CATEGORY_H

#include "stdint.h" 
#include <stdlib.h>
#include "bw-string.h"
#include "bw-result.h"
#include "bw-transaction.h"
#include "cJSON.h"

typedef enum {
    CATEGORY_INCOME,
    CATEGORY_EXPENSES,
    CATEGORY_SAVINGS,
    CATEGORY_DEBT
} BWCategoryType;

typedef struct {
  int id;
  int ordinal;
  BWString title;
  uint64_t amount_planned;
  uint64_t amount_actual;
  uint64_t amount_accumulated;
  BWCategoryType category_type;
  BWTransactionArray transactions;
} BWCategory;

BWResult bw_category_init(
  BWCategory *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  BWCategoryType category_type
);

void bw_category_free(BWCategory *category);
cJSON *bw_category_to_json(BWCategory *category);
BWResult bw_category_from_json(BWCategory *category, cJSON *json);
BWResult bw_category_add_transaction(BWCategory *category, BWTransaction transaction);
BWResult bw_category_remove_transaction(BWCategory *category, BWTransaction *transaction);

typedef struct {
  BWCategory *items;
  size_t length;
  size_t capacity;
} BWCategoryArray;

BWResult bw_category_array_init(BWCategoryArray *array);
BWResult bw_category_array_push_move(BWCategoryArray *array, BWCategory category);
void bw_category_array_free(BWCategoryArray *array);

#endif
