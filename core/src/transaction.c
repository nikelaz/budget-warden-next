#include "transaction.h"

#define TRANSACTION_ARRAY_INITIAL_CAPACITY 4

result transaction_init(
  Transaction *transaction,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount
)
{
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
  transaction->amount = amount;
  transaction->date = date;
  return ok;
}

void transaction_free(Transaction *transaction)
{
  bw_string_free(&transaction->title);
  bw_string_free(&transaction->description);
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

result transaction_array_push(TransactionArray *array, Transaction transaction)
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
