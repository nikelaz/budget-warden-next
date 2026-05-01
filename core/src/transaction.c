#include "transaction.h"

result transaction_init(
  Transaction *transaction,
  const char *title,
  const char *description,
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
  return ok;
}

void transaction_free(Transaction *transaction)
{
  bw_string_free(&transaction->title);
  bw_string_free(&transaction->description);
}
