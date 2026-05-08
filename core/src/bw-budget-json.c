#include "bw-budget-json.h"
#include "cJSON.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

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

static cJSON *bw_transaction_to_json(const BWTransaction *transaction)
{
  if (transaction == NULL)
  {
    return NULL;
  }

  if (transaction->amount > JSON_SAFE_INTEGER_MAX)
  {
    return NULL;
  }

  cJSON *json = cJSON_CreateObject();

  if (json == NULL)
  {
    return NULL;
  }

  char date[11];
  snprintf(
    date,
    sizeof(date),
    "%04d-%02d-%02d",
    transaction->date.year,
    transaction->date.month,
    transaction->date.day
  );

  if (
    cJSON_AddNumberToObject(json, "id", transaction->id) == NULL ||
    cJSON_AddStringToObject(json, "title", transaction->title.data) == NULL ||
    cJSON_AddStringToObject(json, "description", transaction->description.data) == NULL ||
    cJSON_AddStringToObject(json, "date", date) == NULL ||
    cJSON_AddNumberToObject(json, "amount", (double)transaction->amount) == NULL
  )
  {
    cJSON_Delete(json);
    return NULL;
  }

  return json;
}

static BWResult bw_transaction_from_json(BWTransaction *transaction, cJSON *json, BWArena *arena)
{
  if (transaction == NULL || !cJSON_IsObject(json) || arena == NULL)
  {
    return BWResult_ERR;
  }

  int id;
  uint64_t amount;
  BWDate date;
  cJSON *title = json_get_string(json, "title");
  cJSON *description = json_get_string(json, "description");
  cJSON *date_json = json_get_string(json, "date");

  if (
    title == NULL ||
    description == NULL ||
    date_json == NULL ||
    json_get_int(json, "id", &id) == BWResult_ERR ||
    json_get_uint64(json, "amount", &amount) == BWResult_ERR ||
    bw_date_from_string(&date, date_json->valuestring) == BWResult_ERR
  )
  {
    return BWResult_ERR;
  }

  if (bw_transaction_init(transaction, title->valuestring, description->valuestring, date, amount, arena) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  transaction->id = id;
  return BWResult_OK;
}

static cJSON *bw_category_to_json(const BWCategory *category)
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

static BWResult bw_category_from_json(BWCategory *category, cJSON *json, BWArena *arena)
{
  if (category == NULL || !cJSON_IsObject(json) || arena == NULL)
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
    (!bw_category_type_supports_accumulated(category_type) && amount_accumulated != 0) ||
    bw_category_init(category, title->valuestring, amount_planned, amount_actual, amount_accumulated, category_type, arena) == BWResult_ERR
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
      bw_transaction_from_json(&transaction, transaction_json, arena) == BWResult_ERR ||
      bw_transaction_array_push_move(&category->transactions, transaction) == BWResult_ERR
    )
    {
      return BWResult_ERR;
    }
  }

  return BWResult_OK;
}

static cJSON *bw_budget_to_json(const BWBudget *budget)
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

BWString bw_budget_to_json_str(const BWBudget *budget, BWArena *json_arena)
{
  BWString budget_json = {0};

  if (budget == NULL || bw_string_init(&budget_json, json_arena) == BWResult_ERR)
  {
    return budget_json;
  }

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

static BWResult bw_budget_from_json(BWBudget *budget, cJSON *json)
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
      bw_category_from_json(&category, category_json, &budget->arena) == BWResult_ERR ||
      bw_category_array_push_move(&budget->categories, category) == BWResult_ERR
    )
    {
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
