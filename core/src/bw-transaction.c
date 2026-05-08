#include "bw-transaction.h"
#include <string.h>

#define TRANSACTION_ARRAY_INITIAL_CAPACITY 4

BWResult bw_transaction_init(
  BWTransaction *transaction,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount,
  BWArena *arena
)
{
  if (transaction == NULL || title == NULL || description == NULL || arena == NULL)
  {
    return BWResult_ERR;
  }

  BWString title_str;
  
  if (bw_string_init(&title_str, arena) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  if (bw_string_append(&title_str, title) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  BWString description_str;

  if (bw_string_init(&description_str, arena) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  if (bw_string_append(&description_str, description) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  transaction->title = title_str;
  transaction->description = description_str;
  transaction->id = 0;
  transaction->amount = amount;
  transaction->date = date;
  return BWResult_OK;
}

void bw_transaction_clear(BWTransaction *transaction)
{
  if (transaction == NULL)
  {
    return;
  }

  transaction->id = 0;
  bw_string_clear(&transaction->title);
  bw_string_clear(&transaction->description);
  transaction->date = (BWDate){0};
  transaction->amount = 0;
}

BWResult bw_transaction_array_init(BWTransactionArray *array, BWArena *arena)
{
  if (array == NULL || arena == NULL)
  {
    return BWResult_ERR;
  }

  array->items = bw_arena_alloc(arena, BWTransaction, TRANSACTION_ARRAY_INITIAL_CAPACITY);

  if (array->items == NULL)
  {
    array->length = 0;
    array->capacity = 0;
    array->arena = NULL;
    return BWResult_ERR;
  }

  array->length = 0;
  array->capacity = TRANSACTION_ARRAY_INITIAL_CAPACITY;
  array->arena = arena;
  return BWResult_OK;
}

BWResult bw_transaction_array_push_move(BWTransactionArray *array, BWTransaction transaction)
{
  if (array == NULL || array->arena == NULL)
  {
    return BWResult_ERR;
  }

  if (bw_transaction_array_reserve(array, array->length + 1) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  array->items[array->length] = transaction;
  array->length++;
  return BWResult_OK;
}

BWResult bw_transaction_array_reserve(BWTransactionArray *array, size_t capacity)
{
  if (array == NULL || array->arena == NULL)
  {
    return BWResult_ERR;
  }

  if (capacity <= array->capacity)
  {
    return BWResult_OK;
  }

  size_t new_capacity = array->capacity;

  if (new_capacity == 0)
  {
    new_capacity = TRANSACTION_ARRAY_INITIAL_CAPACITY;
  }

  while (new_capacity < capacity)
  {
    if (new_capacity > SIZE_MAX / 2)
    {
      return BWResult_ERR;
    }

    new_capacity *= 2;
  }

  BWTransaction *new_items = bw_arena_alloc(array->arena, BWTransaction, new_capacity);

  if (new_items == NULL)
  {
    return BWResult_ERR;
  }

  if (array->items != NULL && array->length > 0)
  {
    memcpy(new_items, array->items, sizeof(BWTransaction) * array->length);
  }

  array->items = new_items;
  array->capacity = new_capacity;
  return BWResult_OK;
}

void bw_transaction_array_clear(BWTransactionArray *array)
{
  if (array == NULL)
  {
    return;
  }

  array->items = NULL;
  array->length = 0;
  array->capacity = 0;
  array->arena = NULL;
}
