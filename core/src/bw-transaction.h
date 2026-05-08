#ifndef BW_TRANSACTION_H
#define BW_TRANSACTION_H

#include <stdint.h>
#include <stdlib.h>
#include "bw-string.h"
#include "bw-result.h"
#include "bw-date.h"
#include "bw-arena.h"

typedef struct {
  int id;
  BWString title;
  BWString description;
  BWDate date;
  uint64_t amount;
} BWTransaction;

typedef struct {
  BWTransaction *items;
  size_t length;
  size_t capacity;
  BWArena *arena;
} BWTransactionArray;

BWResult bw_transaction_init(
  BWTransaction *transaction,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount,
  BWArena *arena
);

void bw_transaction_clear(BWTransaction *transaction);

BWResult bw_transaction_array_init(BWTransactionArray *array, BWArena *arena);
BWResult bw_transaction_array_reserve(BWTransactionArray *array, size_t capacity);
BWResult bw_transaction_array_push_move(BWTransactionArray *array, BWTransaction transaction);
void bw_transaction_array_clear(BWTransactionArray *array);

#endif
