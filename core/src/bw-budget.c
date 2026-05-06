#include "bw-budget.h"
#include "bw-arena.h"
#include "bw-string.h"
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

static cJSON *json_get_string(cJSON *json, const char *name)
{
  cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);

  if (!cJSON_IsString(item) || item->valuestring == NULL)
  {
    return NULL;
  }

  return item;
}

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

// Todo(Niki): This static method should not be here
static BWResult bw_string_replace(BWString *target, const char *text)
{
  if (target == NULL || text == NULL)
  {
    return BWResult_ERR;
  }

  BWString replacement;

  if (bw_string_init(&replacement) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  if (bw_string_append(&replacement, text) == BWResult_ERR)
  {
    bw_string_free(&replacement);
    return BWResult_ERR;
  }

  bw_string_free(target);
  *target = replacement;
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

BWResult bw_budget_init(
    BWBudget *budget,
    const char *title
)
{
  if (budget == NULL || title == NULL)
  {
    return BWResult_ERR;
  }

  BWString title_str;

  if (bw_string_init(&title_str) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  if (bw_string_append(&title_str, title) == BWResult_ERR)
  {
    bw_string_free(&title_str);
    return BWResult_ERR;
  }

  BWCategoryArray categories;

  if (bw_category_array_init(&categories) == BWResult_ERR)
  {
    bw_string_free(&title_str);
    return BWResult_ERR;
  }

  budget->id = 0;
  budget->title = title_str;
  budget->categories = categories;
  return BWResult_OK;
}

BWResult bw_budget_init_from_template(
  BWBudget *budget,
  const char *template_path
)
{
  if (budget == NULL || template_path == NULL)
  {
    return BWResult_ERR;
  }

  FILE *file = fopen(template_path, "rb");

  if (file == NULL)
  {
    return BWResult_ERR;
  }

  BWString template_file_contents;

  if (bw_string_init(&template_file_contents) == BWResult_ERR)
  {
    fclose(file);
    return BWResult_ERR;
  }

  char buffer[4096];

  while(1)
  {
    size_t bytes_read = fread(buffer, 1, sizeof buffer, file);

    if (bytes_read > 0)
    {
      if (bw_string_append_len(&template_file_contents, buffer, bytes_read) == BWResult_ERR)
      {
        bw_string_free(&template_file_contents);
        fclose(file);
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
        bw_string_free(&template_file_contents);
        fclose(file);
        return BWResult_ERR;
      }
    }
  }

  BWBudget template_budget = {0};
  BWResult budget_from_json_res = bw_budget_from_json_str(&template_budget, template_file_contents.data);

  bw_string_free(&template_file_contents);
  fclose(file);

  if (budget_from_json_res == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  bw_budget_free(budget);
  *budget = template_budget;
  return BWResult_OK;
}

void bw_budget_free(BWBudget *budget)
{
  bw_category_array_free(&budget->categories);
  bw_string_free(&budget->title);
}

cJSON *bw_budget_to_json(BWBudget *budget)
{
  if (budget == NULL)
  {
    return NULL;
  }

  cJSON *json = cJSON_CreateObject();
  cJSON *categories = cJSON_CreateArray();

  if (json == NULL || categories == NULL)
  {
    cJSON_Delete(json);
    cJSON_Delete(categories);
    return NULL;
  }

  if (
    cJSON_AddNumberToObject(json, "id", budget->id) == NULL ||
    cJSON_AddStringToObject(json, "title", budget->title.data) == NULL ||
    !cJSON_AddItemToObject(json, "categories", categories)
  )
  {
    cJSON_Delete(json);
    cJSON_Delete(categories);
    return NULL;
  }

  categories = NULL;

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    cJSON *category = bw_category_to_json(&budget->categories.items[i]);

    if (category == NULL || !cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(json, "categories"), category))
    {
      cJSON_Delete(category);
      cJSON_Delete(json);
      return NULL;
    }
  }

  return json;
}

BWString bw_budget_to_json_str(BWBudget *budget)
{
  BWString budget_json;
  bw_string_init(&budget_json);

  cJSON *json = bw_budget_to_json(budget);

  if (json == NULL)
  {
    return budget_json;
  }

  char *printed = cJSON_PrintUnformatted(json);

  if (printed != NULL)
  {
    bw_string_append(&budget_json, printed);
    cJSON_free(printed);
  }

  cJSON_Delete(json);
  return budget_json;
}

BWResult bw_budget_from_json(BWBudget *budget, cJSON *json)
{
  if (budget == NULL || !cJSON_IsObject(json))
  {
    return BWResult_ERR;
  }

  cJSON *title = json_get_string(json, "title");
  cJSON *categories = cJSON_GetObjectItemCaseSensitive(json, "categories");
  cJSON *id_json = cJSON_GetObjectItemCaseSensitive(json, "id");

  if (
    title == NULL ||
    !cJSON_IsArray(categories) ||
    bw_budget_init(budget, title->valuestring) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  if (id_json != NULL)
  {
    uint64_t id;

    if (
      !cJSON_IsNumber(id_json) ||
      id_json->valuedouble < 0 ||
      id_json->valuedouble > (double)INT32_MAX ||
      (double)(int)id_json->valuedouble != id_json->valuedouble
    )
    {
      bw_budget_free(budget);
      return BWResult_ERR;
    }

    id = (uint64_t)id_json->valuedouble;
    budget->id = (int)id;
  }

  cJSON *category_json = NULL;
  cJSON_ArrayForEach(category_json, categories)
  {
    BWCategory category = {0};

    if (
      bw_category_from_json(&category, category_json) == BWResult_ERR ||
      bw_category_array_push_move(&budget->categories, category) == BWResult_ERR
    )
    {
      if (category.title.data != NULL)
      {
        bw_category_free(&category);
      }

      bw_budget_free(budget);
      return BWResult_ERR;
    }
  }

  return BWResult_OK;
}

BWResult bw_budget_from_json_str(BWBudget *budget, const char *budget_json)
{
  if (budget == NULL || budget_json == NULL)
  {
    return BWResult_ERR;
  }

  cJSON *json = cJSON_Parse(budget_json);

  if (json == NULL)
  {
    return BWResult_ERR;
  }

  BWResult res = bw_budget_from_json(budget, json);
  cJSON_Delete(json);
  return res;
}

BWResult bw_budget_add_category(BWBudget *budget, BWCategory category)
{
  if (budget == NULL)
  {
    return BWResult_ERR;
  }

  category.id = bw_budget_next_category_id(budget);
  category.ordinal = bw_budget_next_category_ordinal(budget, category.category_type);

  return bw_category_array_push_move(&budget->categories, category);
}

BWResult bw_budget_update_category(BWBudget *budget, int category_id, BWCategoryUpdate category_update)
{
  BWCategory *category = bw_budget_find_category(budget, category_id);

  if (category == NULL || category_update.title == NULL)
  {
    return BWResult_ERR;
  }

  if (!category_type_supports_accumulated(category->category_type) && category_update.amount_accumulated != 0)
  {
    return BWResult_ERR;
  }

  if (bw_string_replace(&category->title, category_update.title) == BWResult_ERR)
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
      bw_category_free(&budget->categories.items[i]);

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

  if (category == NULL)
  {
    return BWResult_ERR;
  }

  transaction.id = bw_budget_next_transaction_id(budget);
  return bw_category_add_transaction(category, transaction);
}

BWResult bw_budget_update_transaction(BWBudget *budget, int transaction_id, BWTransactionUpdate transaction_update)
{
  BWCategory *source_category = NULL;
  BWTransaction *source_transaction = NULL;
  BWCategory *target_category = bw_budget_find_category(budget, transaction_update.category_id);

  if (
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

    if (bw_string_init(&title) == BWResult_ERR)
    {
      return BWResult_ERR;
    }

    if (bw_string_append(&title, transaction_update.title) == BWResult_ERR)
    {
      bw_string_free(&title);
      return BWResult_ERR;
    }

    if (bw_string_init(&description) == BWResult_ERR)
    {
      bw_string_free(&title);
      return BWResult_ERR;
    }

    if (bw_string_append(&description, transaction_update.description) == BWResult_ERR)
    {
      bw_string_free(&title);
      bw_string_free(&description);
      return BWResult_ERR;
    }

    if (category_update_actual_amount(source_category, source_transaction->amount, transaction_update.amount) == BWResult_ERR)
    {
      bw_string_free(&title);
      bw_string_free(&description);
      return BWResult_ERR;
    }

    bw_string_free(&source_transaction->title);
    bw_string_free(&source_transaction->description);

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
      transaction_update.amount
    ) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  replacement.id = transaction_id;

  if (bw_category_remove_transaction(source_category, source_transaction) == BWResult_ERR)
  {
    bw_transaction_free(&replacement);
    return BWResult_ERR;
  }

  if (bw_category_add_transaction(target_category, replacement) == BWResult_ERR)
  {
    bw_transaction_free(&replacement);
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
