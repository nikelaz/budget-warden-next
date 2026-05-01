#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "budget.h"
#include "bwdate.h"
#include "result.h"
#include "category.h"
#include "transaction.h"

void test_date_init() {
  BWDate date;

  result date_res = bw_date_init(&date, 2026, 1, 31);

  assert(date_res == ok);
  assert(bw_date_get_year(&date) == 2026);
  assert(bw_date_get_month(&date) == 1);
  assert(bw_date_get_day(&date) == 31);
  printf("(Pass) date_init\n");
}

void test_budget_init() {
  BWDate period_start;
  result period_start_res = bw_date_init(&period_start, 2026, 1, 1);
  assert(period_start_res == ok);

  BWDate period_end;
  result period_end_res = bw_date_init(&period_end, 2026, 1, 31);
  assert(period_end_res == ok);

  Budget budget;

  result budget_res = budget_init(&budget, "Title", period_start, period_end); 

  assert(budget_res == ok);
  assert(strcmp(budget.title.data, "Title") == 0);
  assert(budget.period_start.timestamp == period_start.timestamp);
  assert(budget.period_end.timestamp == period_end.timestamp);
  printf("(Pass) budget_init\n");
}

void test_category_init() {
  Category category;
  
  result category_res = category_init(&category, "x", 100, 99);
  assert(category_res == ok);
  assert(strcmp(category.title.data, "x") == 0);
  assert(category.amount_planned == 100);
  assert(category.amount_actual == 99);
  printf("(Pass) category_init\n");
}

void test_transaction_init() {
  Transaction transaction;

  result transaction_res = transaction_init(&transaction, "x", "y", 100);
  assert(transaction_res == ok);
  assert(strcmp(transaction.title.data, "x") == 0);
  assert(strcmp(transaction.description.data, "y") == 0);
  assert(transaction.amount == 100);
  printf("(Pass) transaction_init\n");
}

int main() {
  test_date_init();
  test_budget_init();
  test_category_init();
  test_transaction_init();
  return 0;
}
