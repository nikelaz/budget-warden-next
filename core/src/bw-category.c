/* 
 * Budget Warden Core
 * Copyright (c) 2026 Lazarov & Co EOOD
 * Author: Nikola Lazarov
 *
 * Licensed under the Source-Available Educational License. 
 * See the LICENSE file in the project root for full terms.
 *
 */

#include "bw-category.h"
#include <string.h>

#define CATEGORY_ARRAY_INITIAL_CAPACITY 4

static int bw_category_type_supports_accumulated(BWCategoryType category_type)
{
  return category_type == CATEGORY_SAVINGS || category_type == CATEGORY_DEBT;
}

BWResult bw_category_init(
  BWCategory *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual,
  uint64_t amount_accumulated,
  BWCategoryType category_type,
  BWArena *arena
)
{
  if (category == NULL || title == NULL || arena == NULL)
  {
    return BWResult_ERR;
  }

  if (!bw_category_type_supports_accumulated(category_type) && amount_accumulated != 0)
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

  BWTransactionArray transactions;

  if (bw_transaction_array_init(&transactions, arena) == BWResult_ERR)
  {
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

void bw_category_clear(BWCategory *category)
{
  if (category == NULL)
  {
    return;
  }

  category->id = 0;
  category->ordinal = 0;
  bw_string_clear(&category->title);
  category->amount_planned = 0;
  category->amount_actual = 0;
  category->amount_accumulated = 0;
  category->category_type = CATEGORY_EXPENSES;
  bw_transaction_array_clear(&category->transactions);
}

BWResult bw_category_add_transaction(BWCategory *category, BWTransaction transaction)
{
  if (category == NULL)
  {
    return BWResult_ERR;
  }

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
  if (category == NULL || transaction == NULL)
  {
    return BWResult_ERR;
  }

  for (size_t i = 0; i < category->transactions.length; i++)
  {
    if (&category->transactions.items[i] == transaction)
    {
      BWTransaction removed = category->transactions.items[i];

      if (removed.amount > category->amount_actual)
      {
        return BWResult_ERR;
      }

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

size_t bw_category_transaction_count(const BWCategory *category)
{
  return category == NULL ? 0 : category->transactions.length;
}

const BWTransaction *bw_category_transaction_at(const BWCategory *category, size_t index)
{
  if (category == NULL || category->transactions.items == NULL || index >= category->transactions.length)
  {
    return NULL;
  }

  return &category->transactions.items[index];
}

BWResult bw_category_array_init(BWCategoryArray *array, BWArena *arena)
{
  if (array == NULL || arena == NULL)
  {
    return BWResult_ERR;
  }

  array->items = bw_arena_alloc(arena, BWCategory, CATEGORY_ARRAY_INITIAL_CAPACITY);

  if (array->items == NULL)
  {
    array->length = 0;
    array->capacity = 0;
    array->arena = NULL;
    return BWResult_ERR;
  }

  array->length = 0;
  array->capacity = CATEGORY_ARRAY_INITIAL_CAPACITY;
  array->arena = arena;
  return BWResult_OK;
}

BWResult bw_category_array_push_move(BWCategoryArray *array, BWCategory category)
{
  if (array == NULL || array->arena == NULL)
  {
    return BWResult_ERR;
  }

  if (array->length == array->capacity)
  {
    size_t new_capacity = array->capacity * 2;
    BWCategory *new_items = bw_arena_alloc(array->arena, BWCategory, new_capacity);

    if (new_items == NULL)
    {
      return BWResult_ERR;
    }

    memcpy(new_items, array->items, sizeof(BWCategory) * array->length);
    array->items = new_items;
    array->capacity = new_capacity;
  }

  array->items[array->length] = category;
  array->length++;
  return BWResult_OK;
}

void bw_category_array_clear(BWCategoryArray *array)
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
