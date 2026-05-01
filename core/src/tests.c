#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "budget.h"
#include "bwdate.h"
#include "result.h"
#include "category.h"
#include "transaction.h"

BWDate test_date() {
  BWDate date;
  result date_res = bw_date_init(&date, 2026, 1, 31);
  assert(date_res == ok);
  return date;
}

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
  assert(budget.categories.length == 0);
  assert(budget.categories.capacity == 4);
  budget_free(&budget);
  printf("(Pass) budget_init\n");
}

void test_category_init() {
  Category category;
  
  result category_res = category_init(&category, "x", 100, 99, 0, CATEGORY_EXPENSES);
  assert(category_res == ok);
  assert(strcmp(category.title.data, "x") == 0);
  assert(category.amount_planned == 100);
  assert(category.amount_actual == 99);
  assert(category.amount_accumulated == 0);
  assert(category.category_type == CATEGORY_EXPENSES);
  assert(category.transactions.length == 0);
  assert(category.transactions.capacity == 4);
  category_free(&category);
  printf("(Pass) category_init\n");
}

void test_category_init_with_accumulated() {
  Category savings;
  result savings_res = category_init(&savings, "Emergency fund", 1000, 0, 250, CATEGORY_SAVINGS);
  assert(savings_res == ok);
  assert(savings.amount_accumulated == 250);
  assert(savings.category_type == CATEGORY_SAVINGS);
  category_free(&savings);

  Category debt;
  result debt_res = category_init(&debt, "Loan", 1000, 0, 400, CATEGORY_DEBT);
  assert(debt_res == ok);
  assert(debt.amount_accumulated == 400);
  assert(debt.category_type == CATEGORY_DEBT);
  category_free(&debt);

  Category income;
  result income_res = category_init(&income, "Paycheck", 1000, 0, 1, CATEGORY_INCOME);
  assert(income_res == err);

  printf("(Pass) category_init_with_accumulated\n");
}

void test_transaction_init() {
  Transaction transaction;
  BWDate date = test_date();

  result transaction_res = transaction_init(&transaction, "x", "y", date, 100);
  assert(transaction_res == ok);
  assert(strcmp(transaction.title.data, "x") == 0);
  assert(strcmp(transaction.description.data, "y") == 0);
  assert(transaction.date.timestamp == date.timestamp);
  assert(transaction.amount == 100);
  transaction_free(&transaction);
  printf("(Pass) transaction_init\n");
}

void test_transaction_array_push() {
  TransactionArray transactions;
  result transactions_res = transaction_array_init(&transactions);
  assert(transactions_res == ok);

  for (int i = 0; i < 5; i++) {
    Transaction transaction;
    result transaction_res = transaction_init(&transaction, "x", "y", test_date(), 100 + i);
    assert(transaction_res == ok);

    result push_res = transaction_array_push(&transactions, transaction);
    assert(push_res == ok);
  }

  assert(transactions.length == 5);
  assert(transactions.capacity == 8);
  assert(transactions.items[4].amount == 104);

  transaction_array_free(&transactions);
  printf("(Pass) transaction_array_push\n");
}

void test_category_array_push() {
  CategoryArray categories;
  result categories_res = category_array_init(&categories);
  assert(categories_res == ok);

  for (int i = 0; i < 5; i++) {
    Category category;
    result category_res = category_init(&category, "x", 100 + i, 99 + i, 0, CATEGORY_EXPENSES);
    assert(category_res == ok);

    result push_res = category_array_push(&categories, category);
    assert(push_res == ok);
  }

  assert(categories.length == 5);
  assert(categories.capacity == 8);
  assert(categories.items[4].amount_planned == 104);
  assert(categories.items[4].amount_actual == 103);

  category_array_free(&categories);
  printf("(Pass) category_array_push\n");
}

void test_category_add_transaction() {
  Category category;
  result category_res = category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == ok);

  Transaction transaction;
  result transaction_res = transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125);
  assert(transaction_res == ok);

  result add_res = category_add_transaction(&category, transaction);
  assert(add_res == ok);
  assert(category.transactions.length == 1);
  assert(category.transactions.items[0].amount == 125);
  assert(category.amount_actual == 125);
  assert(category.amount_accumulated == 0);

  category_free(&category);
  printf("(Pass) category_add_transaction\n");
}

void test_category_remove_transaction() {
  Category category;
  result category_res = category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == ok);

  Transaction first;
  result first_res = transaction_init(&first, "Groceries", "Weekly shop", test_date(), 125);
  assert(first_res == ok);

  Transaction second;
  result second_res = transaction_init(&second, "Coffee", "Morning coffee", test_date(), 5);
  assert(second_res == ok);

  result first_add_res = category_add_transaction(&category, first);
  assert(first_add_res == ok);

  result second_add_res = category_add_transaction(&category, second);
  assert(second_add_res == ok);

  result remove_res = category_remove_transaction(&category, &category.transactions.items[0]);
  assert(remove_res == ok);
  assert(category.transactions.length == 1);
  assert(category.transactions.items[0].amount == 5);
  assert(category.amount_actual == 5);
  assert(category.amount_accumulated == 0);

  category_free(&category);
  printf("(Pass) category_remove_transaction\n");
}

void test_category_transactions_do_not_change_accumulated() {
  Category category;
  result category_res = category_init(&category, "Emergency fund", 500, 0, 250, CATEGORY_SAVINGS);
  assert(category_res == ok);

  Transaction transaction;
  result transaction_res = transaction_init(&transaction, "Deposit", "Monthly saving", test_date(), 125);
  assert(transaction_res == ok);

  result add_res = category_add_transaction(&category, transaction);
  assert(add_res == ok);
  assert(category.amount_actual == 125);
  assert(category.amount_accumulated == 250);

  result remove_res = category_remove_transaction(&category, &category.transactions.items[0]);
  assert(remove_res == ok);
  assert(category.amount_actual == 0);
  assert(category.amount_accumulated == 250);

  category_free(&category);
  printf("(Pass) category_transactions_do_not_change_accumulated\n");
}

void test_category_remove_transaction_not_found() {
  Category category;
  result category_res = category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == ok);

  Transaction stored;
  result stored_res = transaction_init(&stored, "Groceries", "Weekly shop", test_date(), 125);
  assert(stored_res == ok);

  Transaction missing;
  result missing_res = transaction_init(&missing, "Coffee", "Morning coffee", test_date(), 5);
  assert(missing_res == ok);

  result add_res = category_add_transaction(&category, stored);
  assert(add_res == ok);

  result remove_res = category_remove_transaction(&category, &missing);
  assert(remove_res == err);
  assert(category.transactions.length == 1);
  assert(category.amount_actual == 125);

  transaction_free(&missing);
  category_free(&category);
  printf("(Pass) category_remove_transaction_not_found\n");
}

void test_budget_nested_free() {
  BWDate period_start;
  result period_start_res = bw_date_init(&period_start, 2026, 1, 1);
  assert(period_start_res == ok);

  BWDate period_end;
  result period_end_res = bw_date_init(&period_end, 2026, 1, 31);
  assert(period_end_res == ok);

  Budget budget;
  result budget_res = budget_init(&budget, "Title", period_start, period_end);
  assert(budget_res == ok);

  Category category;
  result category_res = category_init(&category, "Food", 500, 250, 0, CATEGORY_EXPENSES);
  assert(category_res == ok);

  Transaction transaction;
  result transaction_res = transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125);
  assert(transaction_res == ok);

  result add_res = category_add_transaction(&category, transaction);
  assert(add_res == ok);

  result category_push_res = category_array_push(&budget.categories, category);
  assert(category_push_res == ok);

  assert(budget.categories.length == 1);
  assert(budget.categories.items[0].transactions.length == 1);
  assert(budget.categories.items[0].transactions.items[0].amount == 125);

  budget_free(&budget);
  printf("(Pass) budget_nested_free\n");
}

int main() {
  test_date_init();
  test_budget_init();
  test_category_init();
  test_category_init_with_accumulated();
  test_transaction_init();
  test_transaction_array_push();
  test_category_array_push();
  test_category_add_transaction();
  test_category_remove_transaction();
  test_category_transactions_do_not_change_accumulated();
  test_category_remove_transaction_not_found();
  test_budget_nested_free();
  return 0;
}
