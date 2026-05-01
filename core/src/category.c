#include "category.h"

#define CATEGORY_ARRAY_INITIAL_CAPACITY 4

static int category_type_supports_accumulated(CategoryType category_type)
{
  return category_type == CATEGORY_SAVINGS || category_type == CATEGORY_DEBT;
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

result category_add_transaction(Category *category, Transaction transaction)
{
  if (UINT64_MAX - category->amount_actual < transaction.amount)
  {
    return err;
  }

  if (transaction_array_push(&category->transactions, transaction) == err)
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

result category_array_push(CategoryArray *array, Category category)
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
