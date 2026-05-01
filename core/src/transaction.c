#include "transaction.h"

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

result transaction_init(
  Transaction *transaction,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount
)
{
  if (transaction == NULL || title == NULL || description == NULL)
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

  BWString description_str;

  if (bw_string_init(&description_str) == err)
  {
    bw_string_free(&title_str);
    return err;
  }

  if (bw_string_append(&description_str, description) == err)
  {
    bw_string_free(&title_str);
    bw_string_free(&description_str);
    return err;
  }

  transaction->title = title_str;
  transaction->description = description_str;
  transaction->id = 0;
  transaction->amount = amount;
  transaction->date = date;
  return ok;
}

void transaction_free(Transaction *transaction)
{
  bw_string_free(&transaction->title);
  bw_string_free(&transaction->description);
}

cJSON *transaction_to_json(Transaction *transaction)
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

result transaction_from_json(Transaction *transaction, cJSON *json)
{
  if (transaction == NULL || !cJSON_IsObject(json))
  {
    return err;
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
    json_get_int(json, "id", &id) == err ||
    json_get_uint64(json, "amount", &amount) == err ||
    bw_date_from_string(&date, date_json->valuestring) == err
  )
  {
    return err;
  }

  if (transaction_init(transaction, title->valuestring, description->valuestring, date, amount) == err)
  {
    return err;
  }

  transaction->id = id;
  return ok;
}

result transaction_array_init(TransactionArray *array)
{
  array->items = malloc(sizeof(Transaction) * TRANSACTION_ARRAY_INITIAL_CAPACITY);

  if (array->items == NULL)
  {
    array->length = 0;
    array->capacity = 0;
    return err;
  }

  array->length = 0;
  array->capacity = TRANSACTION_ARRAY_INITIAL_CAPACITY;
  return ok;
}

result transaction_array_push_move(TransactionArray *array, Transaction transaction)
{
  if (array->length == array->capacity)
  {
    size_t new_capacity = array->capacity * 2;
    Transaction *new_items = realloc(array->items, sizeof(Transaction) * new_capacity);

    if (new_items == NULL)
    {
      return err;
    }

    array->items = new_items;
    array->capacity = new_capacity;
  }

  array->items[array->length] = transaction;
  array->length++;
  return ok;
}

void transaction_array_free(TransactionArray *array)
{
  for (size_t i = 0; i < array->length; i++)
  {
    transaction_free(&array->items[i]);
  }

  free(array->items);
  array->items = NULL;
  array->length = 0;
  array->capacity = 0;
}
