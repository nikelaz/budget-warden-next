#include "budget.h"
#include "bwstring.h"
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

static int category_type_supports_accumulated(CategoryType category_type)
{
  return category_type == CATEGORY_SAVINGS || category_type == CATEGORY_DEBT;
}

static Category *budget_find_category(Budget *budget, int category_id)
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

static result budget_find_transaction(Budget *budget, int transaction_id, Category **category, Transaction **transaction)
{
  if (budget == NULL || budget->categories.items == NULL || category == NULL || transaction == NULL)
  {
    return err;
  }

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    Category *current_category = &budget->categories.items[category_index];

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
        return ok;
      }
    }
  }

  return err;
}

static int budget_next_category_id(Budget *budget)
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

static int budget_next_category_ordinal(Budget *budget, CategoryType category_type)
{
  int max_ordinal = -1;

  if (budget == NULL || budget->categories.items == NULL)
  {
    return 0;
  }

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    Category *category = &budget->categories.items[i];

    if (category->category_type == category_type && category->ordinal > max_ordinal)
    {
      max_ordinal = category->ordinal;
    }
  }

  return max_ordinal + 1;
}

static int budget_next_transaction_id(Budget *budget)
{
  int max_id = 0;

  if (budget == NULL || budget->categories.items == NULL)
  {
    return 1;
  }

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    TransactionArray *transactions = &budget->categories.items[category_index].transactions;

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

static result bw_string_replace(BWString *target, const char *text)
{
  if (target == NULL || text == NULL)
  {
    return err;
  }

  BWString replacement;

  if (bw_string_init(&replacement) == err)
  {
    return err;
  }

  if (bw_string_append(&replacement, text) == err)
  {
    bw_string_free(&replacement);
    return err;
  }

  bw_string_free(target);
  *target = replacement;
  return ok;
}

static result category_update_actual_amount(Category *category, uint64_t old_amount, uint64_t new_amount)
{
  if (category == NULL)
  {
    return err;
  }

  if (new_amount >= old_amount)
  {
    uint64_t increase = new_amount - old_amount;

    if (UINT64_MAX - category->amount_actual < increase)
    {
      return err;
    }

    category->amount_actual += increase;
    return ok;
  }

  uint64_t decrease = old_amount - new_amount;

  if (category->amount_actual < decrease)
  {
    return err;
  }

  category->amount_actual -= decrease;
  return ok;
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

result budget_init(
    Budget *budget,
    const char *title
)
{
  if (budget == NULL || title == NULL)
  {
    return err;
  }

  BWString title_str;

  if (bw_string_init(&title_str) == err)
  {
    return err;
  }

  if (bw_string_append(&title_str, title) == err)
  {
    bw_string_free(&title_str);
    return err;
  }

  CategoryArray categories;

  if (category_array_init(&categories) == err)
  {
    bw_string_free(&title_str);
    return err;
  }

  budget->id = 0;
  budget->title = title_str;
  budget->categories = categories;
  return ok;
}

result budget_init_from_template(
  Budget *budget,
  const char *template_path
)
{
  if (budget == NULL)
  {
    return err;
  }

  FILE *file = fopen(template_path, "rb");

  if (file == NULL)
  {
    return err;
  }

  BWString template_file_contents;
  bw_string_init(&template_file_contents);

  char buffer[4096];

  while(1)
  {
    size_t bytes_read = fread(buffer, 1, sizeof buffer, file);

    if (bytes_read > 0)
    {
      bw_string_append(&template_file_contents, buffer);
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
        return err;
      }
    }
  }

  result budget_from_json_res = budget_from_json_str(budget, template_file_contents.data);

  bw_string_free(&template_file_contents);
  fclose(file);

  if (budget_from_json_res == err)
  {
    return err;
  }

  return ok;
}

void budget_free(Budget *budget)
{
  category_array_free(&budget->categories);
  bw_string_free(&budget->title);
}

cJSON *budget_to_json(Budget *budget)
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
    cJSON *category = category_to_json(&budget->categories.items[i]);

    if (category == NULL || !cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(json, "categories"), category))
    {
      cJSON_Delete(category);
      cJSON_Delete(json);
      return NULL;
    }
  }

  return json;
}

BWString budget_to_json_str(Budget *budget)
{
  BWString budget_json;
  bw_string_init(&budget_json);

  cJSON *json = budget_to_json(budget);

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

result budget_from_json(Budget *budget, cJSON *json)
{
  if (budget == NULL || !cJSON_IsObject(json))
  {
    return err;
  }

  cJSON *title = json_get_string(json, "title");
  cJSON *categories = cJSON_GetObjectItemCaseSensitive(json, "categories");
  cJSON *id_json = cJSON_GetObjectItemCaseSensitive(json, "id");

  if (
    title == NULL ||
    !cJSON_IsArray(categories) ||
    budget_init(budget, title->valuestring) == err
  )
  {
    return err;
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
      budget_free(budget);
      return err;
    }

    id = (uint64_t)id_json->valuedouble;
    budget->id = (int)id;
  }

  cJSON *category_json = NULL;
  cJSON_ArrayForEach(category_json, categories)
  {
    Category category = {0};

    if (
      category_from_json(&category, category_json) == err ||
      category_array_push_move(&budget->categories, category) == err
    )
    {
      if (category.title.data != NULL)
      {
        category_free(&category);
      }

      budget_free(budget);
      return err;
    }
  }

  return ok;
}

result budget_from_json_str(Budget *budget, const char *budget_json)
{
  if (budget == NULL || budget_json == NULL)
  {
    return err;
  }

  cJSON *json = cJSON_Parse(budget_json);

  if (json == NULL)
  {
    return err;
  }

  result res = budget_from_json(budget, json);
  cJSON_Delete(json);
  return res;
}

result budget_add_category(Budget *budget, Category category)
{
  if (budget == NULL)
  {
    return err;
  }

  category.id = budget_next_category_id(budget);
  category.ordinal = budget_next_category_ordinal(budget, category.category_type);

  return category_array_push_move(&budget->categories, category);
}

result budget_update_category(Budget *budget, int category_id, CategoryUpdate category_update)
{
  Category *category = budget_find_category(budget, category_id);

  if (category == NULL || category_update.title == NULL)
  {
    return err;
  }

  if (!category_type_supports_accumulated(category->category_type) && category_update.amount_accumulated != 0)
  {
    return err;
  }

  if (bw_string_replace(&category->title, category_update.title) == err)
  {
    return err;
  }

  category->amount_planned = category_update.amount_planned;
  category->amount_accumulated = category_update.amount_accumulated;
  return ok;
}

result budget_remove_category(Budget *budget, int category_id)
{
  if (budget == NULL || budget->categories.items == NULL)
  {
    return err;
  }

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    if (budget->categories.items[i].id == category_id)
    {
      category_free(&budget->categories.items[i]);

      for (size_t j = i; j + 1 < budget->categories.length; j++)
      {
        budget->categories.items[j] = budget->categories.items[j + 1];
      }

      budget->categories.length--;
      return ok;
    }
  }

  return err;
}

result budget_add_transaction(Budget *budget, int category_id, Transaction transaction)
{
  Category *category = budget_find_category(budget, category_id);

  if (category == NULL)
  {
    return err;
  }

  transaction.id = budget_next_transaction_id(budget);
  return category_add_transaction(category, transaction);
}

result budget_update_transaction(Budget *budget, int transaction_id, TransactionUpdate transaction_update)
{
  Category *source_category = NULL;
  Transaction *source_transaction = NULL;
  Category *target_category = budget_find_category(budget, transaction_update.category_id);

  if (
    target_category == NULL ||
    transaction_update.title == NULL ||
    transaction_update.description == NULL ||
    budget_find_transaction(budget, transaction_id, &source_category, &source_transaction) == err
  )
  {
    return err;
  }

  if (source_category == target_category)
  {
    BWString title;
    BWString description;

    if (bw_string_init(&title) == err)
    {
      return err;
    }

    if (bw_string_append(&title, transaction_update.title) == err)
    {
      bw_string_free(&title);
      return err;
    }

    if (bw_string_init(&description) == err)
    {
      bw_string_free(&title);
      return err;
    }

    if (bw_string_append(&description, transaction_update.description) == err)
    {
      bw_string_free(&title);
      bw_string_free(&description);
      return err;
    }

    if (category_update_actual_amount(source_category, source_transaction->amount, transaction_update.amount) == err)
    {
      bw_string_free(&title);
      bw_string_free(&description);
      return err;
    }

    bw_string_free(&source_transaction->title);
    bw_string_free(&source_transaction->description);

    source_transaction->title = title;
    source_transaction->description = description;
    source_transaction->date = transaction_update.date;
    source_transaction->amount = transaction_update.amount;
    return ok;
  }

  Transaction replacement;

  if (
    transaction_init(
      &replacement,
      transaction_update.title,
      transaction_update.description,
      transaction_update.date,
      transaction_update.amount
    ) == err
  )
  {
    return err;
  }

  replacement.id = transaction_id;

  if (category_remove_transaction(source_category, source_transaction) == err)
  {
    transaction_free(&replacement);
    return err;
  }

  if (category_add_transaction(target_category, replacement) == err)
  {
    transaction_free(&replacement);
    return err;
  }

  return ok;
}

result budget_remove_transaction(Budget *budget, int transaction_id)
{
  Category *category = NULL;
  Transaction *transaction = NULL;

  if (budget_find_transaction(budget, transaction_id, &category, &transaction) == err)
  {
    return err;
  }

  return category_remove_transaction(category, transaction);
}

result budget_reorder_categories(Budget *budget, CategoryType category_type, const int *ordered_category_ids, size_t ordered_category_ids_count)
{
  if (budget == NULL || budget->categories.items == NULL || (ordered_category_ids_count > 0 && ordered_category_ids == NULL))
  {
    return err;
  }

  int ordinal = 0;

  for (size_t id_index = 0; id_index < ordered_category_ids_count; id_index++)
  {
    for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
    {
      Category *category = &budget->categories.items[category_index];

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
    return err;
  }

  for (size_t category_index = 0; category_index < budget->categories.length; category_index++)
  {
    Category *category = &budget->categories.items[category_index];

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
      Category *lhs = &budget->categories.items[remaining_indices[i]];
      Category *rhs = &budget->categories.items[remaining_indices[j]];

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
  return ok;
}
