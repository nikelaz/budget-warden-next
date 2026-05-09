/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

#ifndef BW_CATEGORY_H
#define BW_CATEGORY_H

#include "stdint.h" 
#include <stdlib.h>
#include "bw-string.h"
#include "bw-result.h"
#include "bw-transaction.h"

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
  BWCategoryType category_type,
  BWArena *arena
);

void bw_category_clear(BWCategory *category);
BWResult bw_category_add_transaction(BWCategory *category, BWTransaction transaction);
BWResult bw_category_remove_transaction(BWCategory *category, BWTransaction *transaction);
size_t bw_category_transaction_count(const BWCategory *category);
const BWTransaction *bw_category_transaction_at(const BWCategory *category, size_t index);

typedef struct {
  BWCategory *items;
  size_t length;
  size_t capacity;
  BWArena *arena;
} BWCategoryArray;

BWResult bw_category_array_init(BWCategoryArray *array, BWArena *arena);
BWResult bw_category_array_push_move(BWCategoryArray *array, BWCategory category);
void bw_category_array_clear(BWCategoryArray *array);

#endif
