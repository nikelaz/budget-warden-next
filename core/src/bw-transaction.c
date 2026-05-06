#include "bw-transaction.h"

#define TRANSACTION_ARRAY_INITIAL_CAPACITY 4
#define JSON_SAFE_INTEGER_MAX 9007199254740991ULL

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

BWResult bw_transaction_init(
  BWTransaction *transaction,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount
)
{
  if (transaction == NULL || title == NULL || description == NULL)
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

  BWString description_str;

  if (bw_string_init(&description_str) == BWResult_ERR)
  {
    bw_string_free(&title_str);
    return BWResult_ERR;
  }

  if (bw_string_append(&description_str, description) == BWResult_ERR)
  {
    bw_string_free(&title_str);
    bw_string_free(&description_str);
    return BWResult_ERR;
  }

  transaction->title = title_str;
  transaction->description = description_str;
  transaction->id = 0;
  transaction->amount = amount;
  transaction->date = date;
  return BWResult_OK;
}

void bw_transaction_free(BWTransaction *transaction)
{
  bw_string_free(&transaction->title);
  bw_string_free(&transaction->description);
}

cJSON *bw_transaction_to_json(BWTransaction *transaction)
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

  BWString date = bw_date_to_string(&transaction->date);

  if (
    cJSON_AddNumberToObject(json, "id", transaction->id) == NULL ||
    cJSON_AddStringToObject(json, "title", transaction->title.data) == NULL ||
    cJSON_AddStringToObject(json, "description", transaction->description.data) == NULL ||
    cJSON_AddStringToObject(json, "date", date.data) == NULL ||
    cJSON_AddNumberToObject(json, "amount", (double)transaction->amount) == NULL
  )
  {
    bw_string_free(&date);
    cJSON_Delete(json);
    return NULL;
  }

  bw_string_free(&date);
  return json;
}

BWResult bw_transaction_from_json(BWTransaction *transaction, cJSON *json)
{
  if (transaction == NULL || !cJSON_IsObject(json))
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

  if (bw_transaction_init(transaction, title->valuestring, description->valuestring, date, amount) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  transaction->id = id;
  return BWResult_OK;
}

BWResult bw_transaction_array_init(BWTransactionArray *array)
{
  array->items = malloc(sizeof(BWTransaction) * TRANSACTION_ARRAY_INITIAL_CAPACITY);

  if (array->items == NULL)
  {
    array->length = 0;
    array->capacity = 0;
    return BWResult_ERR;
  }

  array->length = 0;
  array->capacity = TRANSACTION_ARRAY_INITIAL_CAPACITY;
  return BWResult_OK;
}

BWResult bw_transaction_array_push_move(BWTransactionArray *array, BWTransaction transaction)
{
  if (array->length == array->capacity)
  {
    size_t new_capacity = array->capacity * 2;
    BWTransaction *new_items = realloc(array->items, sizeof(BWTransaction) * new_capacity);

    if (new_items == NULL)
    {
      return BWResult_ERR;
    }

    array->items = new_items;
    array->capacity = new_capacity;
  }

  array->items[array->length] = transaction;
  array->length++;
  return BWResult_OK;
}

void bw_transaction_array_free(BWTransactionArray *array)
{
  for (size_t i = 0; i < array->length; i++)
  {
    bw_transaction_free(&array->items[i]);
  }

  free(array->items);
  array->items = NULL;
  array->length = 0;
  array->capacity = 0;
}
