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

// Todo(Niki): I don't like this object, I think it shouldn't exist
typedef struct {
  const char *title;
  uint64_t amount_planned;
  uint64_t amount_accumulated;
} BWCategoryUpdate;

// Todo(Niki): Same as BWCategoryUpdate - it shouldn't exist
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
