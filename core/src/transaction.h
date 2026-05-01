#ifndef TRANSACTION_H
#define TRANSACTION_H

#include <stdint.h>
#include <stdlib.h>
#include "bwstring.h"
#include "result.h"

typedef struct {
  int id;
  BWString title;
  BWString description;
  uint64_t amount;
} Transaction;

typedef struct {
  Transaction *items;
  size_t length;
  size_t capacity;
} TransactionArray;

result transaction_init(
  Transaction *transaction,
  const char *title,
  const char *description,
  uint64_t amount
);

void transaction_free(Transaction *transaction);

result transaction_array_init(TransactionArray *array);
result transaction_array_push(TransactionArray *array, Transaction transaction);
void transaction_array_free(TransactionArray *array);

#endif
