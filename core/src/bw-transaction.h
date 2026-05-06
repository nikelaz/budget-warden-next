#ifndef BW_TRANSACTION_H
#define BW_TRANSACTION_H

#include <stdint.h>
#include <stdlib.h>
#include "bw-string.h"
#include "bw-result.h"
#include "bw-date.h"
#include "cJSON.h"

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
} BWTransactionArray;

BWResult bw_transaction_init(
  BWTransaction *transaction,
  const char *title,
  const char *description,
  BWDate date,
  uint64_t amount
);

void bw_transaction_free(BWTransaction *transaction);
cJSON *bw_transaction_to_json(BWTransaction *transaction);
BWResult bw_transaction_from_json(BWTransaction *transaction, cJSON *json);

BWResult bw_transaction_array_init(BWTransactionArray *array);
BWResult bw_transaction_array_push_move(BWTransactionArray *array, BWTransaction transaction);
void bw_transaction_array_free(BWTransactionArray *array);

#endif
