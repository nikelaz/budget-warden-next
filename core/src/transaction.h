#ifndef TRANSACTION_H
#define TRANSACTION_H

#include <stdint.h>
#include "bwstring.h"
#include "result.h"

typedef struct {
  int id;
  BWString title;
  BWString description;
  uint64_t amount;
} Transaction;


result transaction_init(
  Transaction *transaction,
  const char *title,
  const char *description,
  uint64_t amount
);

void transaction_free(Transaction *transaction);

#endif
