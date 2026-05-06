#include "bw-category.h"
#include <string.h>

#define CATEGORY_ARRAY_INITIAL_CAPACITY 4
#define JSON_SAFE_INTEGER_MAX 9007199254740991ULL

static int bw_category_type_supports_accumulated(BWCategoryType category_type)
{
  return category_type == CATEGORY_SAVINGS || category_type == CATEGORY_DEBT;
}

static const char *bw_category_type_to_string(BWCategoryType category_type)
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

static BWResult bw_category_type_from_string(const char *text, BWCategoryType *category_type)
{
  if (text == NULL || category_type == NULL)
  {
    return BWResult_ERR;
  }

  if (strcmp(text, "income") == 0)
  {
    *category_type = CATEGORY_INCOME;
    return BWResult_OK;
  }

  if (strcmp(text, "expenses") == 0)
  {
    *category_type = CATEGORY_EXPENSES;
    return BWResult_OK;
  }

  if (strcmp(text, "savings") == 0)
  {
    *category_type = CATEGORY_SAVINGS;
    return BWResult_OK;
  }

  if (strcmp(text, "debt") == 0)
  {
    *category_type = CATEGORY_DEBT;
    return BWResult_OK;
  }

  return BWResult_ERR;
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

static BWResult json_get_uint64(cJSON *json, const char *name, uint64_t *value)
{
  cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);

  if (!cJSON_IsNumber(item) || item->valuedouble < 0 || item->valuedouble > (double)JSON_SAFE_INTEGER_MAX)
  {
    return BWResult_ERR;
  }

  uint64_t integer_value = (uint64_t)item->valuedouble;

  if ((double)integer_value != item->valuedouble)
  {
    return BWResult_ERR;
  }

  *value = integer_value;
  return BWResult_OK;
}

static BWResult json_get_int(cJSON *json, const char *name, int *value)
{
  uint64_t unsigned_value;

  if (json_get_uint64(json, name, &unsigned_value) == BWResult_ERR || unsigned_value > INT32_MAX)
  {
    return BWResult_ERR;
  }

  *value = (int)unsigned_value;
  return BWResult_OK;
}

static BWResult json_get_optional_int(cJSON *json, const char *name, int *value, int default_value)
{
  cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);

  if (item == NULL)
  {
    *value = default_value;
    return BWResult_OK;
  }

  return json_get_int(json, name, value);
}

BWResult bw_category_init(
  BWCategory *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  BWCategoryType category_type
)
{
  if (category == NULL || title == NULL)
  {
    return BWResult_ERR;
  }

  if (!bw_category_type_supports_accumulated(category_type) && amount_accumulated != 0)
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

  BWTransactionArray transactions;

  if (bw_transaction_array_init(&transactions) == BWResult_ERR)
  {
    bw_string_free(&title_str);
    return BWResult_ERR;
  }

  category->title = title_str;
  category->id = 0;
  category->ordinal = 0;
  category->amount_planned = amount_planned;
  category->amount_actual = amount_actual;
  category->amount_accumulated = amount_accumulated;
  category->category_type = category_type;
  category->transactions = transactions;
  return BWResult_OK;
}

void bw_category_free(BWCategory *category) {
  bw_transaction_array_free(&category->transactions);
  bw_string_free(&category->title);
}

cJSON *bw_category_to_json(BWCategory *category)
{
  if (category == NULL)
  {
    return NULL;
  }

  const char *category_type = bw_category_type_to_string(category->category_type);

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
    cJSON_AddNumberToObject(json, "ordinal", category->ordinal) == NULL ||
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
    cJSON *transaction = bw_transaction_to_json(&category->transactions.items[i]);

    if (transaction == NULL || !cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(json, "transactions"), transaction))
    {
      cJSON_Delete(transaction);
      cJSON_Delete(json);
      return NULL;
    }
  }

  return json;
}

BWResult bw_category_from_json(BWCategory *category, cJSON *json)
{
  if (category == NULL || !cJSON_IsObject(json))
  {
    return BWResult_ERR;
  }

  int id;
  int ordinal;
  uint64_t amount_planned;
  uint64_t amount_actual;
  uint64_t amount_accumulated;
  BWCategoryType category_type;
  cJSON *title = json_get_string(json, "title");
  cJSON *category_type_json = json_get_string(json, "category_type");
  cJSON *transactions = cJSON_GetObjectItemCaseSensitive(json, "transactions");

  if (
    title == NULL ||
    category_type_json == NULL ||
    !cJSON_IsArray(transactions) ||
    json_get_int(json, "id", &id) == BWResult_ERR ||
    json_get_optional_int(json, "ordinal", &ordinal, 0) == BWResult_ERR ||
    json_get_uint64(json, "amount_planned", &amount_planned) == BWResult_ERR ||
    json_get_uint64(json, "amount_actual", &amount_actual) == BWResult_ERR ||
    json_get_uint64(json, "amount_accumulated", &amount_accumulated) == BWResult_ERR ||
    bw_category_type_from_string(category_type_json->valuestring, &category_type) == BWResult_ERR ||
    bw_category_init(category, title->valuestring, amount_planned, amount_actual, amount_accumulated, category_type) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  category->id = id;
  category->ordinal = ordinal;

  cJSON *transaction_json = NULL;
  cJSON_ArrayForEach(transaction_json, transactions)
  {
    BWTransaction transaction = {0};

    if (
      bw_transaction_from_json(&transaction, transaction_json) == BWResult_ERR ||
      bw_transaction_array_push_move(&category->transactions, transaction) == BWResult_ERR
    )
    {
      if (transaction.title.data != NULL)
      {
        bw_transaction_free(&transaction);
      }

      bw_category_free(category);
      return BWResult_ERR;
    }
  }

  return BWResult_OK;
}

BWResult bw_category_add_transaction(BWCategory *category, BWTransaction transaction)
{
  if (UINT64_MAX - category->amount_actual < transaction.amount)
  {
    return BWResult_ERR;
  }

  if (bw_transaction_array_push_move(&category->transactions, transaction) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  category->amount_actual += transaction.amount;
  return BWResult_OK;
}

BWResult bw_category_remove_transaction(BWCategory *category, BWTransaction *transaction)
{
  for (size_t i = 0; i < category->transactions.length; i++)
  {
    if (&category->transactions.items[i] == transaction)
    {
      BWTransaction removed = category->transactions.items[i];

      if (removed.amount > category->amount_actual)
      {
        return BWResult_ERR;
      }

      bw_transaction_free(&removed);

      for (size_t j = i; j + 1 < category->transactions.length; j++)
      {
        category->transactions.items[j] = category->transactions.items[j + 1];
      }

      category->transactions.length--;
      category->amount_actual -= removed.amount;
      return BWResult_OK;
    }
  }

  return BWResult_ERR;
}

BWResult bw_category_array_init(BWCategoryArray *array)
{
  array->items = malloc(sizeof(BWCategory) * CATEGORY_ARRAY_INITIAL_CAPACITY);

  if (array->items == NULL)
  {
    array->length = 0;
    array->capacity = 0;
    return BWResult_ERR;
  }

  array->length = 0;
  array->capacity = CATEGORY_ARRAY_INITIAL_CAPACITY;
  return BWResult_OK;
}

BWResult bw_category_array_push_move(BWCategoryArray *array, BWCategory category)
{
  if (array->length == array->capacity)
  {
    size_t new_capacity = array->capacity * 2;
    BWCategory *new_items = realloc(array->items, sizeof(BWCategory) * new_capacity);

    if (new_items == NULL)
    {
      return BWResult_ERR;
    }

    array->items = new_items;
    array->capacity = new_capacity;
  }

  array->items[array->length] = category;
  array->length++;
  return BWResult_OK;
}

void bw_category_array_free(BWCategoryArray *array)
{
  for (size_t i = 0; i < array->length; i++)
  {
    bw_category_free(&array->items[i]);
  }

  free(array->items);
  array->items = NULL;
  array->length = 0;
  array->capacity = 0;
}
