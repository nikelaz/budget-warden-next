#ifndef BUDGET_H
#define BUDGET_H

#include "bwstring.h"
#include "result.h"
#include "category.h"
#include "cjson.h"
#include <stddef.h>

typedef struct {
  int id;
  BWString title;
  CategoryArray categories;
} Budget;

typedef struct {
  const char *title;
  uint64_t amount_planned;
  uint64_t amount_accumulated;
} CategoryUpdate;

typedef struct {
  int category_id;
  const char *title;
  const char *description;
  BWDate date;
  uint64_t amount;
} TransactionUpdate;

result budget_init(Budget *budget, const char *title);
result budget_init_from_template(Budget *budget, const char *template_path);
void budget_free(Budget *budget);
cJSON *budget_to_json(Budget *budget);
BWString budget_to_json_str(Budget *budget);
result budget_from_json(Budget *budget, cJSON *json);
result budget_from_json_str(Budget *budget, const char *budget_json);

result budget_add_category(Budget *budget, Category category);
result budget_update_category(Budget *budget, int category_id, CategoryUpdate category_update);
result budget_remove_category(Budget *budget, int category_id);

result budget_add_transaction(Budget *budget, int category_id, Transaction transaction);
result budget_update_transaction(Budget *budget, int transaction_id, TransactionUpdate transaction_update);
result budget_remove_transaction(Budget *budget, int transaction_id);

result budget_reorder_categories(Budget *budget, CategoryType category_type, const int *ordered_category_ids, size_t ordered_category_ids_count);

#endif
