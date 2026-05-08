#ifndef BW_BUDGET_H
#define BW_BUDGET_H

#include "bw-string.h"
#include "bw-result.h"
#include "bw-category.h"
#include "bw-arena.h"
#include <stddef.h>

typedef struct {
  int id;
  BWString title;
  BWCategoryArray categories;
  BWArena arena;
} BWBudget;

typedef struct {
  const char *title;
  uint64_t amount_planned;
  uint64_t amount_accumulated;
} BWCategoryUpdate;

typedef struct {
  int category_id;
  const char *title;
  const char *description;
  BWDate date;
  uint64_t amount;
} BWTransactionUpdate;

// Alloc
BWResult bw_budget_init(BWBudget *budget, const char *title);
BWResult bw_budget_init_from_template(BWBudget *budget, const char *template_path);

// Dealloc
void bw_budget_free(BWBudget *budget);

// Read
size_t bw_budget_category_count(const BWBudget *budget);
const BWCategory *bw_budget_category_at(const BWBudget *budget, size_t index);
const BWCategory *bw_budget_category_by_id(const BWBudget *budget, int category_id);
const BWTransaction *bw_budget_transaction_by_id(
  const BWBudget *budget,
  int transaction_id,
  const BWCategory **category
);

// Categories
BWResult bw_budget_add_category(BWBudget *budget, BWCategory category);
BWResult bw_budget_add_category_values(
  BWBudget *budget,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  BWCategoryType category_type
);
BWResult bw_budget_update_category(
  BWBudget *budget, int category_id,
  BWCategoryUpdate category_update
);
BWResult bw_budget_remove_category(BWBudget *budget, int category_id);
BWResult bw_budget_reorder_categories(
  BWBudget *budget,
  BWCategoryType category_type,
  const int *ordered_category_ids,
  size_t ordered_category_ids_count
);

// Transactions
BWResult bw_budget_add_transaction(
  BWBudget *budget, int category_id,
  BWTransaction transaction
);
BWResult bw_budget_add_transaction_values(
  BWBudget *budget,
  int category_id,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount
);
BWResult bw_budget_update_transaction(
  BWBudget *budget,
  int transaction_id,
  BWTransactionUpdate transaction_update
);
BWResult bw_budget_remove_transaction(BWBudget *budget, int transaction_id);

#endif
