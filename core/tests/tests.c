#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "bw-core.h"

#define TEST_ARENA_CAPACITY (1024 * 1024)

static BWArena test_arena(void)
{
  BWArena arena;
  assert(bw_arena_init(&arena, TEST_ARENA_CAPACITY) == BWResult_OK);
  return arena;
}

static BWDate test_date(void)
{
  BWDate date;
  assert(bw_date_init(&date, 2026, 1, 31) == BWResult_OK);
  return date;
}

static void assert_date_eq(BWDate actual, BWDate expected)
{
  assert(actual.year == expected.year);
  assert(actual.month == expected.month);
  assert(actual.day == expected.day);
}

void test_date_init(void)
{
  BWDate date;
  assert(bw_date_init(&date, 2026, 1, 31) == BWResult_OK);
  assert(date.year == 2026);
  assert(date.month == 1);
  assert(date.day == 31);
  printf("(Pass) date_init\n");
}

void test_date_to_string(void)
{
  BWArena arena = test_arena();
  BWDate date = test_date();
  BWString date_str = bw_date_to_string(&date, &arena);

  assert(strcmp(date_str.data, "2026-01-31") == 0);

  bw_arena_destroy(&arena);
  printf("(Pass) date_to_string\n");
}

void test_date_from_string(void)
{
  BWDate date;

  assert(bw_date_from_string(&date, "2026-01-31") == BWResult_OK);
  assert(date.year == 2026);
  assert(date.month == 1);
  assert(date.day == 31);
  printf("(Pass) date_from_string\n");
}

void test_date_from_string_invalid(void)
{
  BWDate date;

  assert(bw_date_from_string(&date, "2026-2-03") == BWResult_ERR);
  assert(bw_date_from_string(&date, "2026/02/03") == BWResult_ERR);
  assert(bw_date_from_string(&date, NULL) == BWResult_ERR);
  assert(bw_date_from_string(NULL, "2026-02-03") == BWResult_ERR);
  printf("(Pass) date_from_string_invalid\n");
}

void test_budget_init(void)
{
  BWBudget budget;

  assert(bw_budget_init(&budget, "Title") == BWResult_OK);
  assert(budget.id == 0);
  assert(strcmp(budget.title.data, "Title") == 0);
  assert(budget.categories.length == 0);
  assert(budget.categories.capacity == 4);
  assert(budget.categories.arena == &budget.arena);

  bw_budget_free(&budget);
  printf("(Pass) budget_init\n");
}

void test_category_init(void)
{
  BWArena arena = test_arena();
  BWCategory category;

  assert(bw_category_init(&category, "x", 100, 99, 0, CATEGORY_EXPENSES, &arena) == BWResult_OK);
  assert(strcmp(category.title.data, "x") == 0);
  assert(category.amount_planned == 100);
  assert(category.amount_actual == 99);
  assert(category.amount_accumulated == 0);
  assert(category.category_type == CATEGORY_EXPENSES);
  assert(category.transactions.length == 0);
  assert(category.transactions.capacity == 4);
  assert(category.transactions.arena == &arena);

  bw_arena_destroy(&arena);
  printf("(Pass) category_init\n");
}

void test_category_init_with_accumulated(void)
{
  BWArena arena = test_arena();
  BWCategory savings;
  BWCategory debt;
  BWCategory income;

  assert(bw_category_init(&savings, "Emergency fund", 1000, 0, 250, CATEGORY_SAVINGS, &arena) == BWResult_OK);
  assert(savings.amount_accumulated == 250);
  assert(savings.category_type == CATEGORY_SAVINGS);

  assert(bw_category_init(&debt, "Loan", 1000, 0, 400, CATEGORY_DEBT, &arena) == BWResult_OK);
  assert(debt.amount_accumulated == 400);
  assert(debt.category_type == CATEGORY_DEBT);

  assert(bw_category_init(&income, "Paycheck", 1000, 0, 1, CATEGORY_INCOME, &arena) == BWResult_ERR);

  bw_arena_destroy(&arena);
  printf("(Pass) category_init_with_accumulated\n");
}

void test_transaction_init(void)
{
  BWArena arena = test_arena();
  BWTransaction transaction;
  BWDate date = test_date();

  assert(bw_transaction_init(&transaction, "x", "y", date, 100, &arena) == BWResult_OK);
  assert(strcmp(transaction.title.data, "x") == 0);
  assert(strcmp(transaction.description.data, "y") == 0);
  assert_date_eq(transaction.date, date);
  assert(transaction.amount == 100);

  bw_arena_destroy(&arena);
  printf("(Pass) transaction_init\n");
}

void test_transaction_array_push_move(void)
{
  BWArena arena = test_arena();
  BWTransactionArray transactions;

  assert(bw_transaction_array_init(&transactions, &arena) == BWResult_OK);

  for (int i = 0; i < 5; i++)
  {
    BWTransaction transaction;
    assert(bw_transaction_init(&transaction, "x", "y", test_date(), 100 + i, &arena) == BWResult_OK);
    assert(bw_transaction_array_push_move(&transactions, transaction) == BWResult_OK);
  }

  assert(transactions.length == 5);
  assert(transactions.capacity == 8);
  assert(transactions.items[4].amount == 104);

  bw_arena_destroy(&arena);
  printf("(Pass) transaction_array_push_move\n");
}

void test_category_array_push_move(void)
{
  BWArena arena = test_arena();
  BWCategoryArray categories;

  assert(bw_category_array_init(&categories, &arena) == BWResult_OK);

  for (int i = 0; i < 5; i++)
  {
    BWCategory category;
    assert(bw_category_init(&category, "x", 100 + i, 99 + i, 0, CATEGORY_EXPENSES, &arena) == BWResult_OK);
    assert(bw_category_array_push_move(&categories, category) == BWResult_OK);
  }

  assert(categories.length == 5);
  assert(categories.capacity == 8);
  assert(categories.items[4].amount_planned == 104);
  assert(categories.items[4].amount_actual == 103);

  bw_arena_destroy(&arena);
  printf("(Pass) category_array_push_move\n");
}

void test_category_add_transaction(void)
{
  BWArena arena = test_arena();
  BWCategory category;
  BWTransaction transaction;

  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &arena) == BWResult_OK);
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &arena) == BWResult_OK);
  assert(bw_category_add_transaction(&category, transaction) == BWResult_OK);
  assert(category.transactions.length == 1);
  assert(category.transactions.items[0].amount == 125);
  assert(category.amount_actual == 125);
  assert(category.amount_accumulated == 0);

  bw_arena_destroy(&arena);
  printf("(Pass) category_add_transaction\n");
}

void test_category_remove_transaction(void)
{
  BWArena arena = test_arena();
  BWCategory category;
  BWTransaction first;
  BWTransaction second;

  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &arena) == BWResult_OK);
  assert(bw_transaction_init(&first, "Groceries", "Weekly shop", test_date(), 125, &arena) == BWResult_OK);
  assert(bw_transaction_init(&second, "Coffee", "Morning coffee", test_date(), 5, &arena) == BWResult_OK);
  assert(bw_category_add_transaction(&category, first) == BWResult_OK);
  assert(bw_category_add_transaction(&category, second) == BWResult_OK);
  assert(bw_category_remove_transaction(&category, &category.transactions.items[0]) == BWResult_OK);
  assert(category.transactions.length == 1);
  assert(category.transactions.items[0].amount == 5);
  assert(category.amount_actual == 5);

  bw_arena_destroy(&arena);
  printf("(Pass) category_remove_transaction\n");
}

void test_category_transactions_do_not_change_accumulated(void)
{
  BWArena arena = test_arena();
  BWCategory category;
  BWTransaction transaction;

  assert(bw_category_init(&category, "Emergency fund", 500, 0, 250, CATEGORY_SAVINGS, &arena) == BWResult_OK);
  assert(bw_transaction_init(&transaction, "Deposit", "Monthly saving", test_date(), 125, &arena) == BWResult_OK);
  assert(bw_category_add_transaction(&category, transaction) == BWResult_OK);
  assert(category.amount_actual == 125);
  assert(category.amount_accumulated == 250);
  assert(bw_category_remove_transaction(&category, &category.transactions.items[0]) == BWResult_OK);
  assert(category.amount_actual == 0);
  assert(category.amount_accumulated == 250);

  bw_arena_destroy(&arena);
  printf("(Pass) category_transactions_do_not_change_accumulated\n");
}

void test_category_remove_transaction_not_found(void)
{
  BWArena arena = test_arena();
  BWCategory category;
  BWTransaction stored;
  BWTransaction missing;

  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &arena) == BWResult_OK);
  assert(bw_transaction_init(&stored, "Groceries", "Weekly shop", test_date(), 125, &arena) == BWResult_OK);
  assert(bw_transaction_init(&missing, "Coffee", "Morning coffee", test_date(), 5, &arena) == BWResult_OK);
  assert(bw_category_add_transaction(&category, stored) == BWResult_OK);
  assert(bw_category_remove_transaction(&category, &missing) == BWResult_ERR);
  assert(category.transactions.length == 1);
  assert(category.amount_actual == 125);

  bw_arena_destroy(&arena);
  printf("(Pass) category_remove_transaction_not_found\n");
}

void test_budget_nested_free(void)
{
  BWBudget budget;
  BWCategory category;
  BWTransaction transaction;

  assert(bw_budget_init(&budget, "Title") == BWResult_OK);
  assert(bw_category_init(&category, "Food", 500, 250, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &budget.arena) == BWResult_OK);
  assert(bw_category_add_transaction(&category, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);
  assert(budget.categories.length == 1);
  assert(budget.categories.items[0].transactions.length == 1);
  assert(budget.categories.items[0].transactions.items[0].amount == 125);

  bw_budget_free(&budget);
  printf("(Pass) budget_nested_free\n");
}

void test_budget_json_string_round_trip(void)
{
  BWBudget budget;
  BWBudget parsed;
  BWArena json_arena = test_arena();

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  budget.id = 9;

  BWCategory category;
  assert(bw_category_init(&category, "Food", 500, 375, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  category.id = 10;

  BWTransaction transaction;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &budget.arena) == BWResult_OK);
  transaction.id = 11;

  assert(bw_transaction_array_push_move(&category.transactions, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);

  size_t budget_offset = budget.arena.offset;
  BWString json = bw_budget_to_json_str(&budget, &json_arena);
  assert(json.length > 0);
  assert(budget.arena.offset == budget_offset);

  assert(bw_budget_from_json_str(&parsed, json.data) == BWResult_OK);
  assert(parsed.id == 9);
  assert(strcmp(parsed.title.data, "January") == 0);
  assert(parsed.categories.length == 1);
  assert(parsed.categories.items[0].id == 10);
  assert(parsed.categories.items[0].amount_actual == 375);
  assert(parsed.categories.items[0].transactions.length == 1);
  assert(parsed.categories.items[0].transactions.items[0].id == 11);
  assert(parsed.categories.items[0].transactions.items[0].amount == 125);
  assert(parsed.categories.items[0].title.arena == &parsed.arena);
  assert(parsed.categories.items[0].transactions.items[0].title.arena == &parsed.arena);

  bw_budget_free(&parsed);
  bw_arena_destroy(&json_arena);
  bw_budget_free(&budget);
  printf("(Pass) budget_json_string_round_trip\n");
}

void test_budget_init_from_template(void)
{
  BWBudget budget;

  assert(bw_budget_init(&budget, "Draft") == BWResult_OK);
  assert(bw_budget_init_from_template(&budget, "../templates/basic-budget.budget") == BWResult_OK);
  assert(strcmp(budget.title.data, "New User Experience") == 0);
  assert(budget.categories.length == 13);
  assert(strcmp(budget.categories.items[0].title.data, "Salary") == 0);
  assert(budget.categories.items[0].amount_planned == 480000);
  assert(budget.categories.items[12].category_type == CATEGORY_SAVINGS);
  assert(budget.categories.items[0].title.arena == &budget.arena);

  bw_budget_free(&budget);
  printf("(Pass) budget_init_from_template\n");
}

void test_budget_init_from_template_missing_file_keeps_budget(void)
{
  BWBudget budget;

  assert(bw_budget_init(&budget, "Draft") == BWResult_OK);
  assert(bw_budget_init_from_template(&budget, "./src/missing-template.budget") == BWResult_ERR);
  assert(strcmp(budget.title.data, "Draft") == 0);
  assert(budget.categories.length == 0);

  bw_budget_free(&budget);
  printf("(Pass) budget_init_from_template_missing_file_keeps_budget\n");
}

void test_budget_add_category(void)
{
  BWBudget budget;
  BWCategory existing;
  BWCategory category;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&existing, "Rent", 1000, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  existing.id = 4;
  existing.ordinal = 2;
  assert(bw_category_array_push_move(&budget.categories, existing) == BWResult_OK);
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  assert(bw_budget_add_category(&budget, category) == BWResult_OK);
  assert(budget.categories.length == 2);
  assert(budget.categories.items[1].id == 5);
  assert(budget.categories.items[1].ordinal == 3);
  assert(budget.categories.items[1].title.arena == &budget.arena);

  bw_budget_free(&budget);
  printf("(Pass) budget_add_category\n");
}

void test_budget_update_category(void)
{
  BWBudget budget;
  BWCategory category;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&category, "Old", 500, 125, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  category.id = 3;
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);

  BWCategoryUpdate invalid = { "Invalid", 600, 1 };
  assert(bw_budget_update_category(&budget, 3, invalid) == BWResult_ERR);
  assert(strcmp(budget.categories.items[0].title.data, "Old") == 0);

  BWCategoryUpdate update = { "New", 600, 0 };
  assert(bw_budget_update_category(&budget, 3, update) == BWResult_OK);
  assert(strcmp(budget.categories.items[0].title.data, "New") == 0);
  assert(budget.categories.items[0].amount_planned == 600);
  assert(budget.categories.items[0].amount_actual == 125);
  assert(budget.categories.items[0].amount_accumulated == 0);
  assert(budget.categories.items[0].title.arena == &budget.arena);

  bw_budget_free(&budget);
  printf("(Pass) budget_update_category\n");
}

void test_budget_remove_category(void)
{
  BWBudget budget;
  BWCategory first;
  BWCategory second;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&first, "Food", 500, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  first.id = 1;
  assert(bw_category_array_push_move(&budget.categories, first) == BWResult_OK);
  assert(bw_category_init(&second, "Rent", 1000, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  second.id = 2;
  assert(bw_category_array_push_move(&budget.categories, second) == BWResult_OK);
  assert(bw_budget_remove_category(&budget, 1) == BWResult_OK);
  assert(budget.categories.length == 1);
  assert(budget.categories.items[0].id == 2);
  assert(strcmp(budget.categories.items[0].title.data, "Rent") == 0);
  assert(bw_budget_remove_category(&budget, 99) == BWResult_ERR);

  bw_budget_free(&budget);
  printf("(Pass) budget_remove_category\n");
}

void test_budget_add_transaction(void)
{
  BWBudget budget;
  BWCategory category;
  BWTransaction existing;
  BWTransaction transaction;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  category.id = 2;
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);
  assert(bw_transaction_init(&existing, "Coffee", "Morning", test_date(), 5, &budget.arena) == BWResult_OK);
  existing.id = 7;
  assert(bw_category_add_transaction(&budget.categories.items[0], existing) == BWResult_OK);
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &budget.arena) == BWResult_OK);
  assert(bw_budget_add_transaction(&budget, 2, transaction) == BWResult_OK);
  assert(budget.categories.items[0].transactions.length == 2);
  assert(budget.categories.items[0].transactions.items[1].id == 8);
  assert(budget.categories.items[0].amount_actual == 130);
  assert(budget.categories.items[0].transactions.items[1].title.arena == &budget.arena);

  bw_budget_free(&budget);
  printf("(Pass) budget_add_transaction\n");
}

void test_budget_update_transaction_same_category(void)
{
  BWBudget budget;
  BWCategory category;
  BWTransaction transaction;
  BWDate updated_date;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  category.id = 2;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &budget.arena) == BWResult_OK);
  transaction.id = 8;
  assert(bw_category_add_transaction(&category, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);
  assert(bw_date_init(&updated_date, 2026, 2, 1) == BWResult_OK);

  BWTransactionUpdate update = { 2, "Market", "Monthly shop", updated_date, 150 };
  assert(bw_budget_update_transaction(&budget, 8, update) == BWResult_OK);
  assert(strcmp(budget.categories.items[0].transactions.items[0].title.data, "Market") == 0);
  assert(strcmp(budget.categories.items[0].transactions.items[0].description.data, "Monthly shop") == 0);
  assert_date_eq(budget.categories.items[0].transactions.items[0].date, updated_date);
  assert(budget.categories.items[0].transactions.items[0].amount == 150);
  assert(budget.categories.items[0].amount_actual == 150);

  BWTransactionUpdate decrease = { 2, "Market", "Monthly shop", updated_date, 50 };
  assert(bw_budget_update_transaction(&budget, 8, decrease) == BWResult_OK);
  assert(budget.categories.items[0].transactions.items[0].amount == 50);
  assert(budget.categories.items[0].amount_actual == 50);
  assert(budget.categories.items[0].transactions.items[0].title.arena == &budget.arena);

  bw_budget_free(&budget);
  printf("(Pass) budget_update_transaction_same_category\n");
}

void test_budget_update_transaction_move_category(void)
{
  BWBudget budget;
  BWCategory source;
  BWCategory target;
  BWTransaction transaction;
  BWDate updated_date;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&source, "Food", 500, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  source.id = 2;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &budget.arena) == BWResult_OK);
  transaction.id = 8;
  assert(bw_category_add_transaction(&source, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, source) == BWResult_OK);
  assert(bw_category_init(&target, "Savings", 500, 10, 250, CATEGORY_SAVINGS, &budget.arena) == BWResult_OK);
  target.id = 3;
  assert(bw_category_array_push_move(&budget.categories, target) == BWResult_OK);
  assert(bw_date_init(&updated_date, 2026, 2, 1) == BWResult_OK);

  BWTransactionUpdate update = { 3, "Transfer", "Emergency fund", updated_date, 50 };
  assert(bw_budget_update_transaction(&budget, 8, update) == BWResult_OK);
  assert(budget.categories.items[0].transactions.length == 0);
  assert(budget.categories.items[0].amount_actual == 0);
  assert(budget.categories.items[1].transactions.length == 1);
  assert(budget.categories.items[1].transactions.items[0].id == 8);
  assert(strcmp(budget.categories.items[1].transactions.items[0].title.data, "Transfer") == 0);
  assert(budget.categories.items[1].amount_actual == 60);
  assert(budget.categories.items[1].amount_accumulated == 250);

  bw_budget_free(&budget);
  printf("(Pass) budget_update_transaction_move_category\n");
}

void test_budget_remove_transaction(void)
{
  BWBudget budget;
  BWCategory category;
  BWTransaction transaction;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  category.id = 2;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125, &budget.arena) == BWResult_OK);
  transaction.id = 8;
  assert(bw_category_add_transaction(&category, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);
  assert(bw_budget_remove_transaction(&budget, 8) == BWResult_OK);
  assert(budget.categories.items[0].transactions.length == 0);
  assert(budget.categories.items[0].amount_actual == 0);
  assert(bw_budget_remove_transaction(&budget, 8) == BWResult_ERR);

  bw_budget_free(&budget);
  printf("(Pass) budget_remove_transaction\n");
}

void test_budget_reorder_categories(void)
{
  BWBudget budget;
  BWCategory first;
  BWCategory second;
  BWCategory third;
  BWCategory income;

  assert(bw_budget_init(&budget, "January") == BWResult_OK);
  assert(bw_category_init(&first, "First", 100, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  first.id = 1;
  first.ordinal = 0;
  assert(bw_category_array_push_move(&budget.categories, first) == BWResult_OK);
  assert(bw_category_init(&second, "Second", 100, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  second.id = 2;
  second.ordinal = 1;
  assert(bw_category_array_push_move(&budget.categories, second) == BWResult_OK);
  assert(bw_category_init(&third, "Third", 100, 0, 0, CATEGORY_EXPENSES, &budget.arena) == BWResult_OK);
  third.id = 3;
  third.ordinal = 2;
  assert(bw_category_array_push_move(&budget.categories, third) == BWResult_OK);
  assert(bw_category_init(&income, "Income", 100, 0, 0, CATEGORY_INCOME, &budget.arena) == BWResult_OK);
  income.id = 4;
  income.ordinal = 0;
  assert(bw_category_array_push_move(&budget.categories, income) == BWResult_OK);

  int ordered_ids[] = { 3, 99 };
  assert(bw_budget_reorder_categories(&budget, CATEGORY_EXPENSES, ordered_ids, 2) == BWResult_OK);
  assert(budget.categories.items[0].ordinal == 1);
  assert(budget.categories.items[1].ordinal == 2);
  assert(budget.categories.items[2].ordinal == 0);
  assert(budget.categories.items[3].ordinal == 0);

  bw_budget_free(&budget);
  printf("(Pass) budget_reorder_categories\n");
}

void test_json_failure_invalid_text(void)
{
  BWBudget budget;

  assert(bw_budget_from_json_str(&budget, "{\"title\"") == BWResult_ERR);
  printf("(Pass) json_failure_invalid_text\n");
}

void test_json_failure_missing_required_fields(void)
{
  BWBudget budget;

  assert(bw_budget_from_json_str(&budget, "{\"title\":\"x\",\"categories\":[{}]}") == BWResult_ERR);
  printf("(Pass) json_failure_missing_required_fields\n");
}

void test_json_failure_invalid_date(void)
{
  BWBudget budget;
  const char *json = "{\"title\":\"x\",\"categories\":[{\"id\":1,\"title\":\"c\",\"amount_planned\":1,\"amount_actual\":1,\"amount_accumulated\":0,\"category_type\":\"expenses\",\"transactions\":[{\"id\":1,\"title\":\"x\",\"description\":\"y\",\"date\":\"2026/02/03\",\"amount\":1}]}]}";

  assert(bw_budget_from_json_str(&budget, json) == BWResult_ERR);
  printf("(Pass) json_failure_invalid_date\n");
}

void test_json_failure_invalid_category_type(void)
{
  BWBudget budget;
  const char *json = "{\"title\":\"x\",\"categories\":[{\"id\":1,\"title\":\"x\",\"amount_planned\":1,\"amount_actual\":1,\"amount_accumulated\":0,\"category_type\":\"other\",\"transactions\":[]}]}";

  assert(bw_budget_from_json_str(&budget, json) == BWResult_ERR);
  printf("(Pass) json_failure_invalid_category_type\n");
}

void test_json_failure_invalid_accumulated(void)
{
  BWBudget budget;
  const char *json = "{\"title\":\"x\",\"categories\":[{\"id\":1,\"title\":\"x\",\"amount_planned\":1,\"amount_actual\":1,\"amount_accumulated\":1,\"category_type\":\"income\",\"transactions\":[]}]}";

  assert(bw_budget_from_json_str(&budget, json) == BWResult_ERR);
  printf("(Pass) json_failure_invalid_accumulated\n");
}

void test_json_failure_large_amount(void)
{
  BWBudget budget;
  const char *json = "{\"title\":\"x\",\"categories\":[{\"id\":1,\"title\":\"c\",\"amount_planned\":1,\"amount_actual\":1,\"amount_accumulated\":0,\"category_type\":\"expenses\",\"transactions\":[{\"id\":1,\"title\":\"x\",\"description\":\"y\",\"date\":\"2026-01-31\",\"amount\":9007199254740992}]}]}";

  assert(bw_budget_from_json_str(&budget, json) == BWResult_ERR);
  printf("(Pass) json_failure_large_amount\n");
}

int main(void)
{
  test_date_init();
  test_date_to_string();
  test_date_from_string();
  test_date_from_string_invalid();
  test_budget_init();
  test_category_init();
  test_category_init_with_accumulated();
  test_transaction_init();
  test_transaction_array_push_move();
  test_category_array_push_move();
  test_category_add_transaction();
  test_category_remove_transaction();
  test_category_transactions_do_not_change_accumulated();
  test_category_remove_transaction_not_found();
  test_budget_nested_free();
  test_budget_json_string_round_trip();
  test_budget_init_from_template();
  test_budget_init_from_template_missing_file_keeps_budget();
  test_budget_add_category();
  test_budget_update_category();
  test_budget_remove_category();
  test_budget_add_transaction();
  test_budget_update_transaction_same_category();
  test_budget_update_transaction_move_category();
  test_budget_remove_transaction();
  test_budget_reorder_categories();
  test_json_failure_invalid_text();
  test_json_failure_missing_required_fields();
  test_json_failure_invalid_date();
  test_json_failure_invalid_category_type();
  test_json_failure_invalid_accumulated();
  test_json_failure_large_amount();
  return 0;
}
