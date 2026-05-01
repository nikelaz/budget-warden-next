#include "category.h"
#include <string.h>

#define CATEGORY_ARRAY_INITIAL_CAPACITY 4
#define JSON_SAFE_INTEGER_MAX 9007199254740991ULL

static int category_type_supports_accumulated(CategoryType category_type)
{
  return category_type == CATEGORY_SAVINGS || category_type == CATEGORY_DEBT;
}

static const char *category_type_to_string(CategoryType category_type)
{
  switch (category_type)
  {
    case CATEGORY_INCOME:
      return "income";
    case CATEGORY_EXPENSES:
      return "expenses";
    case CATEGORY_SAVINGS:
      return "savings";
    case CATEGORY_DEBT:
      return "debt";
  }

  return NULL;
}

static result category_type_from_string(const char *text, CategoryType *category_type)
{
  if (text == NULL || category_type == NULL)
  {
    return err;
  }

  if (strcmp(text, "income") == 0)
  {
    *category_type = CATEGORY_INCOME;
    return ok;
  }

  if (strcmp(text, "expenses") == 0)
  {
    *category_type = CATEGORY_EXPENSES;
    return ok;
  }

  if (strcmp(text, "savings") == 0)
  {
    *category_type = CATEGORY_SAVINGS;
    return ok;
  }

  if (strcmp(text, "debt") == 0)
  {
    *category_type = CATEGORY_DEBT;
    return ok;
  }

  return err;
}

static cJSON *json_get_string(cJSON *json, const char *name)
{
  cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);

  if (!cJSON_IsString(item) || item->valuestring == NULL)
  {
    return NULL;
  }

  return item;
}

static result json_get_uint64(cJSON *json, const char *name, uint64_t *value)
{
  cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);

  if (!cJSON_IsNumber(item) || item->valuedouble < 0 || item->valuedouble > (double)JSON_SAFE_INTEGER_MAX)
  {
    return err;
  }

  uint64_t integer_value = (uint64_t)item->valuedouble;

  if ((double)integer_value != item->valuedouble)
  {
    return err;
  }

  *value = integer_value;
  return ok;
}

static result json_get_int(cJSON *json, const char *name, int *value)
{
  uint64_t unsigned_value;

  if (json_get_uint64(json, name, &unsigned_value) == err || unsigned_value > INT32_MAX)
  {
    return err;
  }

  *value = (int)unsigned_value;
  return ok;
}

result category_init(
  Category *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  CategoryType category_type
)
{
  if (category == NULL || title == NULL)
  {
    return err;
  }

  if (!category_type_supports_accumulated(category_type) && amount_accumulated != 0)
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

  TransactionArray transactions;

  if (transaction_array_init(&transactions) == err)
  {
    bw_string_free(&title_str);
    return err;
  }

  category->title = title_str;
  category->id = 0;
  category->amount_planned = amount_planned;
  category->amount_actual = amount_actual;
  category->amount_accumulated = amount_accumulated;
  category->category_type = category_type;
  category->transactions = transactions;
  return ok;
}

void category_free(Category *category) {
  transaction_array_free(&category->transactions);
  bw_string_free(&category->title);
}

cJSON *category_to_json(Category *category)
{
  if (category == NULL)
  {
    return NULL;
  }

  const char *category_type = category_type_to_string(category->category_type);

  if (
    category_type == NULL ||
    category->amount_planned > JSON_SAFE_INTEGER_MAX ||
    category->amount_actual > JSON_SAFE_INTEGER_MAX ||
    category->amount_accumulated > JSON_SAFE_INTEGER_MAX
  )
  {
    return NULL;
  }

  cJSON *json = cJSON_CreateObject();
  cJSON *transactions = cJSON_CreateArray();

  if (json == NULL || transactions == NULL)
  {
    cJSON_Delete(json);
    cJSON_Delete(transactions);
    return NULL;
  }

  if (
    cJSON_AddNumberToObject(json, "id", category->id) == NULL ||
    cJSON_AddStringToObject(json, "title", category->title.data) == NULL ||
    cJSON_AddNumberToObject(json, "amount_planned", (double)category->amount_planned) == NULL ||
    cJSON_AddNumberToObject(json, "amount_actual", (double)category->amount_actual) == NULL ||
    cJSON_AddNumberToObject(json, "amount_accumulated", (double)category->amount_accumulated) == NULL ||
    cJSON_AddStringToObject(json, "category_type", category_type) == NULL ||
    !cJSON_AddItemToObject(json, "transactions", transactions)
  )
  {
    cJSON_Delete(json);
    cJSON_Delete(transactions);
    return NULL;
  }

  transactions = NULL;

  for (size_t i = 0; i < category->transactions.length; i++)
  {
    cJSON *transaction = transaction_to_json(&category->transactions.items[i]);

    if (transaction == NULL || !cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(json, "transactions"), transaction))
    {
      cJSON_Delete(transaction);
      cJSON_Delete(json);
      return NULL;
    }
  }

  return json;
}

result category_from_json(Category *category, cJSON *json)
{
  if (category == NULL || !cJSON_IsObject(json))
  {
    return err;
  }

  int id;
  uint64_t amount_planned;
  uint64_t amount_actual;
  uint64_t amount_accumulated;
  CategoryType category_type;
  cJSON *title = json_get_string(json, "title");
  cJSON *category_type_json = json_get_string(json, "category_type");
  cJSON *transactions = cJSON_GetObjectItemCaseSensitive(json, "transactions");

  if (
    title == NULL ||
    category_type_json == NULL ||
    !cJSON_IsArray(transactions) ||
    json_get_int(json, "id", &id) == err ||
    json_get_uint64(json, "amount_planned", &amount_planned) == err ||
    json_get_uint64(json, "amount_actual", &amount_actual) == err ||
    json_get_uint64(json, "amount_accumulated", &amount_accumulated) == err ||
    category_type_from_string(category_type_json->valuestring, &category_type) == err ||
    category_init(category, title->valuestring, amount_planned, amount_actual, amount_accumulated, category_type) == err
  )
  {
    return err;
  }

  category->id = id;

  cJSON *transaction_json = NULL;
  cJSON_ArrayForEach(transaction_json, transactions)
  {
    Transaction transaction = {0};

    if (
      transaction_from_json(&transaction, transaction_json) == err ||
      transaction_array_push_move(&category->transactions, transaction) == err
    )
    {
      if (transaction.title.data != NULL)
      {
        transaction_free(&transaction);
      }

      category_free(category);
      return err;
    }
  }

  return ok;
}

result category_add_transaction(Category *category, Transaction transaction)
{
  if (UINT64_MAX - category->amount_actual < transaction.amount)
  {
    return err;
  }

  if (transaction_array_push_move(&category->transactions, transaction) == err)
  {
    return err;
  }

  category->amount_actual += transaction.amount;
  return ok;
}

result category_remove_transaction(Category *category, Transaction *transaction)
{
  for (size_t i = 0; i < category->transactions.length; i++)
  {
    if (&category->transactions.items[i] == transaction)
    {
      Transaction removed = category->transactions.items[i];

      if (removed.amount > category->amount_actual)
      {
        return err;
      }

      transaction_free(&removed);

      for (size_t j = i; j + 1 < category->transactions.length; j++)
      {
        category->transactions.items[j] = category->transactions.items[j + 1];
      }

      category->transactions.length--;
      category->amount_actual -= removed.amount;
      return ok;
    }
  }

  return err;
}

result category_array_init(CategoryArray *array)
{
  array->items = malloc(sizeof(Category) * CATEGORY_ARRAY_INITIAL_CAPACITY);

  if (array->items == NULL)
  {
    array->length = 0;
    array->capacity = 0;
    return err;
  }

  array->length = 0;
  array->capacity = CATEGORY_ARRAY_INITIAL_CAPACITY;
  return ok;
}

result category_array_push_move(CategoryArray *array, Category category)
{
  if (array->length == array->capacity)
  {
    size_t new_capacity = array->capacity * 2;
    Category *new_items = realloc(array->items, sizeof(Category) * new_capacity);

    if (new_items == NULL)
    {
      return err;
    }

    array->items = new_items;
    array->capacity = new_capacity;
  }

  array->items[array->length] = category;
  array->length++;
  return ok;
}

void category_array_free(CategoryArray *array)
{
  for (size_t i = 0; i < array->length; i++)
  {
    category_free(&array->items[i]);
  }

  free(array->items);
  array->items = NULL;
  array->length = 0;
  array->capacity = 0;
}
