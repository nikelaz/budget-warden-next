#include "bw-budget.h"
#include "bw-budget-json.h"
#include "bw-string.h"
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

#define BUDGET_ARENA_CAPACITY (1024 * 1024)

static int category_type_supports_accumulated(BWCategoryType category_type)
{
  return category_type == CATEGORY_SAVINGS || category_type == CATEGORY_DEBT;
}

static BWCategory *bw_budget_find_category(BWBudget *budget, int category_id)
{
  if (budget == NULL || budget->categories.items == NULL)
  {
    return NULL;
  }

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    if (budget->categories.items[i].id == category_id)
    {
      return &budget->categories.items[i];
    }
  }

  return NULL;
}

static BWResult bw_budget_find_transaction(BWBudget *budget, int transaction_id, BWCategory **category, BWTransaction **transaction)
{
  if (budget == NULL || budget->categories.items == NULL || category == NULL || transaction == NULL)
  {
    return BWResult_ERR;
  }

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    BWCategory *current_category = &budget->categories.items[category_index];

    if (current_category->transactions.items == NULL)
    {
      continue;
    }

    for (size_t transaction_index = 0; transaction_index < current_category->transactions.length; transaction_index++)
    {
      if (current_category->transactions.items[transaction_index].id == transaction_id)
      {
        *category = current_category;
        *transaction = &current_category->transactions.items[transaction_index];
        return BWResult_OK;
      }
    }
  }

  return BWResult_ERR;
}

static int bw_budget_next_category_id(BWBudget *budget)
{
  int max_id = 0;

  if (budget == NULL || budget->categories.items == NULL)
  {
    return 1;
  }

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    if (budget->categories.items[i].id > max_id)
    {
      max_id = budget->categories.items[i].id;
    }
  }

  return max_id + 1;
}

static int bw_budget_next_category_ordinal(BWBudget *budget, BWCategoryType category_type)
{
  int max_ordinal = -1;

  if (budget == NULL || budget->categories.items == NULL)
  {
    return 0;
  }

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    BWCategory *category = &budget->categories.items[i];

    if (category->category_type == category_type && category->ordinal > max_ordinal)
    {
      max_ordinal = category->ordinal;
    }
  }

  return max_ordinal + 1;
}

static int bw_budget_next_transaction_id(BWBudget *budget)
{
  int max_id = 0;

  if (budget == NULL || budget->categories.items == NULL)
  {
    return 1;
  }

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    BWTransactionArray *transactions = &budget->categories.items[category_index].transactions;

    if (transactions->items == NULL)
    {
      continue;
    }

    for (size_t transaction_index = 0; transaction_index < transactions->length; transaction_index++)
    {
      if (transactions->items[transaction_index].id > max_id)
      {
        max_id = transactions->items[transaction_index].id;
      }
    }
  }

  return max_id + 1;
}

static BWResult bw_string_replace(BWString *target, const char *text, BWArena *arena)
{
  if (target == NULL || text == NULL || arena == NULL)
  {
    return BWResult_ERR;
  }

  BWString replacement;

  if (bw_string_init(&replacement, arena) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  if (bw_string_append(&replacement, text) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  *target = replacement;
  return BWResult_OK;
}

static BWResult bw_budget_clone_transaction(BWBudget *budget, const BWTransaction *source, BWTransaction *target)
{
  if (budget == NULL || source == NULL || target == NULL)
  {
    return BWResult_ERR;
  }

  if (
    bw_transaction_init(
      target,
      source->title.data,
      source->description.data,
      source->date,
      source->amount,
      &budget->arena
    ) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  target->id = source->id;
  return BWResult_OK;
}

static BWResult bw_budget_clone_category(BWBudget *budget, const BWCategory *source, BWCategory *target)
{
  if (budget == NULL || source == NULL || target == NULL)
  {
    return BWResult_ERR;
  }

  if (
    bw_category_init(
      target,
      source->title.data,
      source->amount_planned,
      source->amount_actual,
      source->amount_accumulated,
      source->category_type,
      &budget->arena
    ) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  target->id = source->id;
  target->ordinal = source->ordinal;

  for (size_t i = 0; i < source->transactions.length; i++)
  {
    BWTransaction transaction = {0};

    if (
      bw_budget_clone_transaction(budget, &source->transactions.items[i], &transaction) == BWResult_ERR ||
      bw_transaction_array_push_move(&target->transactions, transaction) == BWResult_ERR
    )
    {
      return BWResult_ERR;
    }
  }

  return BWResult_OK;
}

static BWResult category_update_actual_amount(BWCategory *category, uint64_t old_amount, uint64_t new_amount)
{
  if (category == NULL)
  {
    return BWResult_ERR;
  }

  if (new_amount >= old_amount)
  {
    uint64_t increase = new_amount - old_amount;

    if (UINT64_MAX - category->amount_actual < increase)
    {
      return BWResult_ERR;
    }

    category->amount_actual += increase;
    return BWResult_OK;
  }

  uint64_t decrease = old_amount - new_amount;

  if (category->amount_actual < decrease)
  {
    return BWResult_ERR;
  }

  category->amount_actual -= decrease;
  return BWResult_OK;
}

static int int_array_contains(const int *items, size_t count, int value)
{
  for (size_t i = 0; i < count; i++)
  {
    if (items[i] == value)
    {
      return 1;
    }
  }

  return 0;
}

static void bw_budget_rebind_arena(BWBudget *budget)
{
  if (budget == NULL)
  {
    return;
  }

  budget->title.arena = &budget->arena;
  budget->categories.arena = &budget->arena;

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    BWCategory *category = &budget->categories.items[category_index];
    category->title.arena = &budget->arena;
    category->transactions.arena = &budget->arena;

    for (size_t transaction_index = 0; transaction_index < category->transactions.length; transaction_index++)
    {
      BWTransaction *transaction = &category->transactions.items[transaction_index];
      transaction->title.arena = &budget->arena;
      transaction->description.arena = &budget->arena;
    }
  }
}

BWResult bw_budget_init(BWBudget *budget, const char *title)
{
  if (budget == NULL || title == NULL)
  {
    return BWResult_ERR;
  }

  BWArena arena;
  if (bw_arena_init(&arena, BUDGET_ARENA_CAPACITY) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  budget->id = 0;
  budget->arena = arena;

  BWString title_str;

  if (bw_string_init(&title_str, &budget->arena) == BWResult_ERR)
  {
    bw_arena_destroy(&budget->arena);
    return BWResult_ERR;
  }

  if (bw_string_append(&title_str, title) == BWResult_ERR)
  {
    bw_arena_destroy(&budget->arena);
    return BWResult_ERR;
  }

  BWCategoryArray categories;

  if (bw_category_array_init(&categories, &budget->arena) == BWResult_ERR)
  {
    bw_arena_destroy(&budget->arena);
    return BWResult_ERR;
  }

  budget->title = title_str;
  budget->categories = categories;
  return BWResult_OK;
}

BWResult bw_budget_init_from_template(BWBudget *budget, const char *template_path)
{
  if (budget == NULL || template_path == NULL)
  {
    return BWResult_ERR;
  }

  BWArena json_arena;
  if (bw_arena_init(&json_arena, BUDGET_ARENA_CAPACITY) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  FILE *file = fopen(template_path, "rb");

  if (file == NULL)
  {
    bw_arena_destroy(&json_arena);
    return BWResult_ERR;
  }

  BWString template_file_contents;

  if (bw_string_init(&template_file_contents, &json_arena) == BWResult_ERR)
  {
    fclose(file);
    bw_arena_destroy(&json_arena);
    return BWResult_ERR;
  }

  char buffer[4096];

  while (1)
  {
    size_t bytes_read = fread(buffer, 1, sizeof buffer, file);

    if (bytes_read > 0)
    {
      if (bw_string_append_len(&template_file_contents, buffer, bytes_read) == BWResult_ERR)
      {
        fclose(file);
        bw_arena_destroy(&json_arena);
        return BWResult_ERR;
      }
    }

    if (bytes_read < sizeof buffer)
    {
      if (feof(file))
      {
        break;
      }

      if (ferror(file))
      {
        fclose(file);
        bw_arena_destroy(&json_arena);
        return BWResult_ERR;
      }
    }
  }

  BWBudget template_budget = {0};
  BWResult budget_from_json_res = bw_budget_from_json_str(&template_budget, template_file_contents.data);

  fclose(file);
  bw_arena_destroy(&json_arena);

  if (budget_from_json_res == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  bw_budget_free(budget);
  *budget = template_budget;
  bw_budget_rebind_arena(budget);
  return BWResult_OK;
}

void bw_budget_free(BWBudget *budget)
{
  if (budget == NULL)
  {
    return;
  }

  bw_arena_destroy(&budget->arena);
  budget->id = 0;
  bw_string_clear(&budget->title);
  bw_category_array_clear(&budget->categories);
}

BWResult bw_budget_add_category(BWBudget *budget, BWCategory category)
{
  if (budget == NULL)
  {
    return BWResult_ERR;
  }

  BWCategory stored = {0};
  category.id = bw_budget_next_category_id(budget);
  category.ordinal = bw_budget_next_category_ordinal(budget, category.category_type);

  if (bw_budget_clone_category(budget, &category, &stored) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  return bw_category_array_push_move(&budget->categories, stored);
}

BWResult bw_budget_add_category_values(
  BWBudget *budget,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  BWCategoryType category_type
)
{
  if (budget == NULL || title == NULL)
  {
    return BWResult_ERR;
  }

  BWCategory stored = {0};

  if (
    bw_category_init(
      &stored,
      title,
      amount_planned,
      amount_actual,
      amount_accumulated,
      category_type,
      &budget->arena
    ) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  stored.id = bw_budget_next_category_id(budget);
  stored.ordinal = bw_budget_next_category_ordinal(budget, category_type);

  return bw_category_array_push_move(&budget->categories, stored);
}

BWResult bw_budget_update_category(BWBudget *budget, int category_id, BWCategoryUpdate category_update)
{
  BWCategory *category = bw_budget_find_category(budget, category_id);

  if (budget == NULL || category == NULL || category_update.title == NULL)
  {
    return BWResult_ERR;
  }

  if (!category_type_supports_accumulated(category->category_type) && category_update.amount_accumulated != 0)
  {
    return BWResult_ERR;
  }

  if (bw_string_replace(&category->title, category_update.title, &budget->arena) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  category->amount_planned = category_update.amount_planned;
  category->amount_accumulated = category_update.amount_accumulated;
  return BWResult_OK;
}

BWResult bw_budget_remove_category(BWBudget *budget, int category_id)
{
  if (budget == NULL || budget->categories.items == NULL)
  {
    return BWResult_ERR;
  }

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    if (budget->categories.items[i].id == category_id)
    {
      for (size_t j = i; j + 1 < budget->categories.length; j++)
      {
        budget->categories.items[j] = budget->categories.items[j + 1];
      }

      budget->categories.length--;
      return BWResult_OK;
    }
  }

  return BWResult_ERR;
}

BWResult bw_budget_add_transaction(BWBudget *budget, int category_id, BWTransaction transaction)
{
  BWCategory *category = bw_budget_find_category(budget, category_id);

  if (budget == NULL || category == NULL)
  {
    return BWResult_ERR;
  }

  BWTransaction stored = {0};
  transaction.id = bw_budget_next_transaction_id(budget);

  if (bw_budget_clone_transaction(budget, &transaction, &stored) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  return bw_category_add_transaction(category, stored);
}

BWResult bw_budget_add_transaction_values(
  BWBudget *budget,
  int category_id,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount
)
{
  BWCategory *category = bw_budget_find_category(budget, category_id);

  if (budget == NULL || category == NULL || title == NULL || description == NULL)
  {
    return BWResult_ERR;
  }

  if (UINT64_MAX - category->amount_actual < amount)
  {
    return BWResult_ERR;
  }

  BWTransaction stored = {0};

  if (bw_transaction_init(&stored, title, description, date, amount, &budget->arena) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  stored.id = bw_budget_next_transaction_id(budget);
  return bw_category_add_transaction(category, stored);
}

BWResult bw_budget_update_transaction(BWBudget *budget, int transaction_id, BWTransactionUpdate transaction_update)
{
  BWCategory *source_category = NULL;
  BWTransaction *source_transaction = NULL;
  BWCategory *target_category = bw_budget_find_category(budget, transaction_update.category_id);

  if (
    budget == NULL ||
    target_category == NULL ||
    transaction_update.title == NULL ||
    transaction_update.description == NULL ||
    bw_budget_find_transaction(budget, transaction_id, &source_category, &source_transaction) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  if (source_category == target_category)
  {
    BWString title;
    BWString description;

    if (bw_string_init(&title, &budget->arena) == BWResult_ERR)
    {
      return BWResult_ERR;
    }

    if (bw_string_append(&title, transaction_update.title) == BWResult_ERR)
    {
      return BWResult_ERR;
    }

    if (bw_string_init(&description, &budget->arena) == BWResult_ERR)
    {
      return BWResult_ERR;
    }

    if (bw_string_append(&description, transaction_update.description) == BWResult_ERR)
    {
      return BWResult_ERR;
    }

    if (category_update_actual_amount(source_category, source_transaction->amount, transaction_update.amount) == BWResult_ERR)
    {
      return BWResult_ERR;
    }

    source_transaction->title = title;
    source_transaction->description = description;
    source_transaction->date = transaction_update.date;
    source_transaction->amount = transaction_update.amount;
    return BWResult_OK;
  }

  BWTransaction replacement;

  if (
    bw_transaction_init(
      &replacement,
      transaction_update.title,
      transaction_update.description,
      transaction_update.date,
      transaction_update.amount,
      &budget->arena
    ) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  replacement.id = transaction_id;

  if (UINT64_MAX - target_category->amount_actual < replacement.amount)
  {
    return BWResult_ERR;
  }

  if (bw_category_remove_transaction(source_category, source_transaction) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  if (bw_category_add_transaction(target_category, replacement) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  return BWResult_OK;
}

BWResult bw_budget_remove_transaction(BWBudget *budget, int transaction_id)
{
  BWCategory *category = NULL;
  BWTransaction *transaction = NULL;

  if (bw_budget_find_transaction(budget, transaction_id, &category, &transaction) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  return bw_category_remove_transaction(category, transaction);
}

BWResult bw_budget_reorder_categories(
  BWBudget *budget,
  BWCategoryType category_type,
  const int *ordered_category_ids,
  size_t ordered_category_ids_count
)
{
  if (budget == NULL || budget->categories.items == NULL || (ordered_category_ids_count > 0 && ordered_category_ids == NULL))
  {
    return BWResult_ERR;
  }

  int ordinal = 0;

  for (size_t id_index = 0; id_index < ordered_category_ids_count; id_index++)
  {
    for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
    {
      BWCategory *category = &budget->categories.items[category_index];

      if (category->category_type == category_type && category->id == ordered_category_ids[id_index])
      {
        category->ordinal = ordinal;
        ordinal++;
        break;
      }
    }
  }

  size_t remaining_count = 0;
  size_t *remaining_indices = malloc(sizeof(size_t) * budget->categories.length);

  if (remaining_indices == NULL && budget->categories.length > 0)
  {
    return BWResult_ERR;
  }

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    BWCategory *category = &budget->categories.items[category_index];

    if (
      category->category_type == category_type &&
      !int_array_contains(ordered_category_ids, ordered_category_ids_count, category->id)
    )
    {
      remaining_indices[remaining_count] = category_index;
      remaining_count++;
    }
  }

  for (size_t i = 0; i < remaining_count; i++)
  {
    for (size_t j = i + 1; j < remaining_count; j++)
    {
      BWCategory *lhs = &budget->categories.items[remaining_indices[i]];
      BWCategory *rhs = &budget->categories.items[remaining_indices[j]];

      if (
        rhs->ordinal < lhs->ordinal ||
        (rhs->ordinal == lhs->ordinal && rhs->id < lhs->id)
      )
      {
        size_t swap = remaining_indices[i];
        remaining_indices[i] = remaining_indices[j];
        remaining_indices[j] = swap;
      }
    }
  }

  for (size_t i = 0; i < remaining_count; i++)
  {
    budget->categories.items[remaining_indices[i]].ordinal = ordinal;
    ordinal++;
  }

  free(remaining_indices);
  return BWResult_OK;
}
