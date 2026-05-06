#include <stdio.h>
#include <assert.h>
#include <string.h>
#include "bw-core.h"

BWDate test_date() {
  BWDate date;
  BWResult date_res = bw_date_init(&date, 2026, 1, 31);
  assert(date_res == BWResult_OK);
  return date;
}

void assert_date_eq(BWDate actual, BWDate expected) {
  assert(actual.year == expected.year);
  assert(actual.month == expected.month);
  assert(actual.day == expected.day);
}

void test_date_init() {
  BWDate date;

  BWResult date_res = bw_date_init(&date, 2026, 1, 31);

  assert(date_res == BWResult_OK);
  assert(date.year == 2026);
  assert(date.month == 1);
  assert(date.day == 31);
  printf("(Pass) date_init\n");
}

void test_date_to_string() {
  BWDate date = test_date();
  BWString date_str = bw_date_to_string(&date);
  assert(strcmp(date_str.data, "2026-01-31") == 0);
  bw_string_free(&date_str);
  printf("(Pass) date_to_string\n");
}

void test_date_from_string() {
  BWDate date;
  BWResult date_res = bw_date_from_string(&date, "2026-01-31");

  assert(date_res == BWResult_OK);
  assert(date.year == 2026);
  assert(date.month == 1);
  assert(date.day == 31);
  printf("(Pass) date_from_string\n");
}

void test_date_from_string_invalid() {
  BWDate date;

  assert(bw_date_from_string(&date, "2026-2-03") == BWResult_ERR);
  assert(bw_date_from_string(&date, "2026/02/03") == BWResult_ERR);
  assert(bw_date_from_string(&date, NULL) == BWResult_ERR);
  assert(bw_date_from_string(NULL, "2026-02-03") == BWResult_ERR);
  printf("(Pass) date_from_string_invalid\n");
}

void test_budget_init() {
  BWBudget budget;

  BWResult budget_res = bw_budget_init(&budget, "Title"); 

  assert(budget_res == BWResult_OK);
  assert(budget.id == 0);
  assert(strcmp(budget.title.data, "Title") == 0);
  assert(budget.categories.length == 0);
  assert(budget.categories.capacity == 4);
  bw_budget_free(&budget);
  printf("(Pass) budget_init\n");
}

void test_category_init() {
  BWCategory category;
  
  BWResult category_res = bw_category_init(&category, "x", 100, 99, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);
  assert(strcmp(category.title.data, "x") == 0);
  assert(category.amount_planned == 100);
  assert(category.amount_actual == 99);
  assert(category.amount_accumulated == 0);
  assert(category.category_type == CATEGORY_EXPENSES);
  assert(category.transactions.length == 0);
  assert(category.transactions.capacity == 4);
  bw_category_free(&category);
  printf("(Pass) category_init\n");
}

void test_category_init_with_accumulated() {
  BWCategory savings;
  BWResult savings_res = bw_category_init(&savings, "Emergency fund", 1000, 0, 250, CATEGORY_SAVINGS);
  assert(savings_res == BWResult_OK);
  assert(savings.amount_accumulated == 250);
  assert(savings.category_type == CATEGORY_SAVINGS);
  bw_category_free(&savings);

  BWCategory debt;
  BWResult debt_res = bw_category_init(&debt, "Loan", 1000, 0, 400, CATEGORY_DEBT);
  assert(debt_res == BWResult_OK);
  assert(debt.amount_accumulated == 400);
  assert(debt.category_type == CATEGORY_DEBT);
  bw_category_free(&debt);

  BWCategory income;
  BWResult income_res = bw_category_init(&income, "Paycheck", 1000, 0, 1, CATEGORY_INCOME);
  assert(income_res == BWResult_ERR);

  printf("(Pass) category_init_with_accumulated\n");
}

void test_transaction_init() {
  BWTransaction transaction;
  BWDate date = test_date();

  BWResult transaction_res = bw_transaction_init(&transaction, "x", "y", date, 100);
  assert(transaction_res == BWResult_OK);
  assert(strcmp(transaction.title.data, "x") == 0);
  assert(strcmp(transaction.description.data, "y") == 0);
  assert_date_eq(transaction.date, date);
  assert(transaction.amount == 100);
  bw_transaction_free(&transaction);
  printf("(Pass) transaction_init\n");
}

void test_transaction_json_round_trip() {
  BWTransaction transaction;
  BWDate date = test_date();

  BWResult transaction_res = bw_transaction_init(&transaction, "Rent", "May rent", date, 1500);
  assert(transaction_res == BWResult_OK);
  transaction.id = 42;

  cJSON *json = bw_transaction_to_json(&transaction);
  assert(json != NULL);
  assert(cJSON_GetObjectItemCaseSensitive(json, "id")->valuedouble == 42);
  assert(strcmp(cJSON_GetObjectItemCaseSensitive(json, "title")->valuestring, "Rent") == 0);
  assert(strcmp(cJSON_GetObjectItemCaseSensitive(json, "description")->valuestring, "May rent") == 0);
  assert(strcmp(cJSON_GetObjectItemCaseSensitive(json, "date")->valuestring, "2026-01-31") == 0);
  assert(cJSON_GetObjectItemCaseSensitive(json, "amount")->valuedouble == 1500);

  BWTransaction parsed;
  BWResult parse_res = bw_transaction_from_json(&parsed, json);
  assert(parse_res == BWResult_OK);
  assert(parsed.id == 42);
  assert(strcmp(parsed.title.data, "Rent") == 0);
  assert(strcmp(parsed.description.data, "May rent") == 0);
  assert_date_eq(parsed.date, date);
  assert(parsed.amount == 1500);

  bw_transaction_free(&parsed);
  cJSON_Delete(json);
  bw_transaction_free(&transaction);
  printf("(Pass) transaction_json_round_trip\n");
}

void test_transaction_array_push_move() {
  BWTransactionArray transactions;
  BWResult transactions_res = bw_transaction_array_init(&transactions);
  assert(transactions_res == BWResult_OK);

  for (int i = 0; i < 5; i++) {
    BWTransaction transaction;
    BWResult transaction_res = bw_transaction_init(&transaction, "x", "y", test_date(), 100 + i);
    assert(transaction_res == BWResult_OK);

    BWResult push_res = bw_transaction_array_push_move(&transactions, transaction);
    assert(push_res == BWResult_OK);
  }

  assert(transactions.length == 5);
  assert(transactions.capacity == 8);
  assert(transactions.items[4].amount == 104);

  bw_transaction_array_free(&transactions);
  printf("(Pass) transaction_array_push_move\n");
}

void test_category_array_push_move() {
  BWCategoryArray categories;
  BWResult categories_res = bw_category_array_init(&categories);
  assert(categories_res == BWResult_OK);

  for (int i = 0; i < 5; i++) {
    BWCategory category;
    BWResult category_res = bw_category_init(&category, "x", 100 + i, 99 + i, 0, CATEGORY_EXPENSES);
    assert(category_res == BWResult_OK);

    BWResult push_res = bw_category_array_push_move(&categories, category);
    assert(push_res == BWResult_OK);
  }

  assert(categories.length == 5);
  assert(categories.capacity == 8);
  assert(categories.items[4].amount_planned == 104);
  assert(categories.items[4].amount_actual == 103);

  bw_category_array_free(&categories);
  printf("(Pass) category_array_push_move\n");
}

void test_category_json_round_trip() {
  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Emergency fund", 1000, 99, 250, CATEGORY_SAVINGS);
  assert(category_res == BWResult_OK);
  category.id = 7;
  category.ordinal = 3;

  BWTransaction transaction;
  BWResult transaction_res = bw_transaction_init(&transaction, "Deposit", "Monthly saving", test_date(), 125);
  assert(transaction_res == BWResult_OK);
  transaction.id = 8;

  BWResult transaction_push_res = bw_transaction_array_push_move(&category.transactions, transaction);
  assert(transaction_push_res == BWResult_OK);

  cJSON *json = bw_category_to_json(&category);
  assert(json != NULL);
  assert(cJSON_GetObjectItemCaseSensitive(json, "id")->valuedouble == 7);
  assert(cJSON_GetObjectItemCaseSensitive(json, "ordinal")->valuedouble == 3);
  assert(strcmp(cJSON_GetObjectItemCaseSensitive(json, "category_type")->valuestring, "savings") == 0);
  assert(cJSON_GetObjectItemCaseSensitive(json, "amount_accumulated")->valuedouble == 250);
  assert(cJSON_GetArraySize(cJSON_GetObjectItemCaseSensitive(json, "transactions")) == 1);

  BWCategory parsed;
  BWResult parse_res = bw_category_from_json(&parsed, json);
  assert(parse_res == BWResult_OK);
  assert(parsed.id == 7);
  assert(parsed.ordinal == 3);
  assert(strcmp(parsed.title.data, "Emergency fund") == 0);
  assert(parsed.amount_planned == 1000);
  assert(parsed.amount_actual == 99);
  assert(parsed.amount_accumulated == 250);
  assert(parsed.category_type == CATEGORY_SAVINGS);
  assert(parsed.transactions.length == 1);
  assert(parsed.transactions.items[0].id == 8);
  assert(parsed.transactions.items[0].amount == 125);

  bw_category_free(&parsed);
  cJSON_Delete(json);
  bw_category_free(&category);
  printf("(Pass) category_json_round_trip\n");
}

void test_category_add_transaction() {
  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);

  BWTransaction transaction;
  BWResult transaction_res = bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125);
  assert(transaction_res == BWResult_OK);

  BWResult add_res = bw_category_add_transaction(&category, transaction);
  assert(add_res == BWResult_OK);
  assert(category.transactions.length == 1);
  assert(category.transactions.items[0].amount == 125);
  assert(category.amount_actual == 125);
  assert(category.amount_accumulated == 0);

  bw_category_free(&category);
  printf("(Pass) category_add_transaction\n");
}

void test_category_remove_transaction() {
  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);

  BWTransaction first;
  BWResult first_res = bw_transaction_init(&first, "Groceries", "Weekly shop", test_date(), 125);
  assert(first_res == BWResult_OK);

  BWTransaction second;
  BWResult second_res = bw_transaction_init(&second, "Coffee", "Morning coffee", test_date(), 5);
  assert(second_res == BWResult_OK);

  BWResult first_add_res = bw_category_add_transaction(&category, first);
  assert(first_add_res == BWResult_OK);

  BWResult second_add_res = bw_category_add_transaction(&category, second);
  assert(second_add_res == BWResult_OK);

  BWResult remove_res = bw_category_remove_transaction(&category, &category.transactions.items[0]);
  assert(remove_res == BWResult_OK);
  assert(category.transactions.length == 1);
  assert(category.transactions.items[0].amount == 5);
  assert(category.amount_actual == 5);
  assert(category.amount_accumulated == 0);

  bw_category_free(&category);
  printf("(Pass) category_remove_transaction\n");
}

void test_category_transactions_do_not_change_accumulated() {
  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Emergency fund", 500, 0, 250, CATEGORY_SAVINGS);
  assert(category_res == BWResult_OK);

  BWTransaction transaction;
  BWResult transaction_res = bw_transaction_init(&transaction, "Deposit", "Monthly saving", test_date(), 125);
  assert(transaction_res == BWResult_OK);

  BWResult add_res = bw_category_add_transaction(&category, transaction);
  assert(add_res == BWResult_OK);
  assert(category.amount_actual == 125);
  assert(category.amount_accumulated == 250);

  BWResult remove_res = bw_category_remove_transaction(&category, &category.transactions.items[0]);
  assert(remove_res == BWResult_OK);
  assert(category.amount_actual == 0);
  assert(category.amount_accumulated == 250);

  bw_category_free(&category);
  printf("(Pass) category_transactions_do_not_change_accumulated\n");
}

void test_category_remove_transaction_not_found() {
  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);

  BWTransaction stored;
  BWResult stored_res = bw_transaction_init(&stored, "Groceries", "Weekly shop", test_date(), 125);
  assert(stored_res == BWResult_OK);

  BWTransaction missing;
  BWResult missing_res = bw_transaction_init(&missing, "Coffee", "Morning coffee", test_date(), 5);
  assert(missing_res == BWResult_OK);

  BWResult add_res = bw_category_add_transaction(&category, stored);
  assert(add_res == BWResult_OK);

  BWResult remove_res = bw_category_remove_transaction(&category, &missing);
  assert(remove_res == BWResult_ERR);
  assert(category.transactions.length == 1);
  assert(category.amount_actual == 125);

  bw_transaction_free(&missing);
  bw_category_free(&category);
  printf("(Pass) category_remove_transaction_not_found\n");
}

void test_budget_nested_free() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "Title");
  assert(budget_res == BWResult_OK);

  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Food", 500, 250, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);

  BWTransaction transaction;
  BWResult transaction_res = bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125);
  assert(transaction_res == BWResult_OK);

  BWResult add_res = bw_category_add_transaction(&category, transaction);
  assert(add_res == BWResult_OK);

  BWResult category_push_res = bw_category_array_push_move(&budget.categories, category);
  assert(category_push_res == BWResult_OK);

  assert(budget.categories.length == 1);
  assert(budget.categories.items[0].transactions.length == 1);
  assert(budget.categories.items[0].transactions.items[0].amount == 125);

  bw_budget_free(&budget);
  printf("(Pass) budget_nested_free\n");
}

void test_budget_json_string_round_trip() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "January");
  assert(budget_res == BWResult_OK);
  budget.id = 9;

  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Food", 500, 375, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);
  category.id = 10;

  BWTransaction transaction;
  BWResult transaction_res = bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125);
  assert(transaction_res == BWResult_OK);
  transaction.id = 11;

  BWResult transaction_push_res = bw_transaction_array_push_move(&category.transactions, transaction);
  assert(transaction_push_res == BWResult_OK);

  BWResult category_push_res = bw_category_array_push_move(&budget.categories, category);
  assert(category_push_res == BWResult_OK);

  BWString json = bw_budget_to_json_str(&budget);
  assert(json.length > 0);

  BWBudget parsed;
  BWResult parse_res = bw_budget_from_json_str(&parsed, json.data);
  assert(parse_res == BWResult_OK);
  assert(parsed.id == 9);
  assert(strcmp(parsed.title.data, "January") == 0);
  assert(parsed.categories.length == 1);
  assert(parsed.categories.items[0].id == 10);
  assert(parsed.categories.items[0].amount_actual == 375);
  assert(parsed.categories.items[0].transactions.length == 1);
  assert(parsed.categories.items[0].transactions.items[0].id == 11);
  assert(parsed.categories.items[0].transactions.items[0].amount == 125);

  bw_budget_free(&parsed);
  bw_string_free(&json);
  bw_budget_free(&budget);
  printf("(Pass) budget_json_string_round_trip\n");
}

void test_budget_init_from_template() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "Draft");
  assert(budget_res == BWResult_OK);

  BWResult template_res = bw_budget_init_from_template(&budget, "../templates/basic-budget.budget");
  assert(template_res == BWResult_OK);
  assert(strcmp(budget.title.data, "New User Experience") == 0);
  assert(budget.categories.length == 13);
  assert(strcmp(budget.categories.items[0].title.data, "Salary") == 0);
  assert(budget.categories.items[0].amount_planned == 480000);
  assert(budget.categories.items[12].category_type == CATEGORY_SAVINGS);

  bw_budget_free(&budget);
  printf("(Pass) budget_init_from_template\n");
}

void test_budget_init_from_template_missing_file_keeps_budget() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "Draft");
  assert(budget_res == BWResult_OK);

  BWResult template_res = bw_budget_init_from_template(&budget, "./src/missing-template.budget");
  assert(template_res == BWResult_ERR);
  assert(strcmp(budget.title.data, "Draft") == 0);
  assert(budget.categories.length == 0);

  bw_budget_free(&budget);
  printf("(Pass) budget_init_from_template_missing_file_keeps_budget\n");
}

void test_budget_add_category() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "January");
  assert(budget_res == BWResult_OK);

  BWCategory existing;
  BWResult existing_res = bw_category_init(&existing, "Rent", 1000, 0, 0, CATEGORY_EXPENSES);
  assert(existing_res == BWResult_OK);
  existing.id = 4;
  existing.ordinal = 2;
  assert(bw_category_array_push_move(&budget.categories, existing) == BWResult_OK);

  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);

  assert(bw_budget_add_category(&budget, category) == BWResult_OK);
  assert(budget.categories.length == 2);
  assert(budget.categories.items[1].id == 5);
  assert(budget.categories.items[1].ordinal == 3);

  bw_budget_free(&budget);
  printf("(Pass) budget_add_category\n");
}

void test_budget_update_category() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "January");
  assert(budget_res == BWResult_OK);

  BWCategory category;
  BWResult category_res = bw_category_init(&category, "Old", 500, 125, 0, CATEGORY_EXPENSES);
  assert(category_res == BWResult_OK);
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

  bw_budget_free(&budget);
  printf("(Pass) budget_update_category\n");
}

void test_budget_remove_category() {
  BWBudget budget;
  BWResult budget_res = bw_budget_init(&budget, "January");
  assert(budget_res == BWResult_OK);

  BWCategory first;
  assert(bw_category_init(&first, "Food", 500, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  first.id = 1;
  assert(bw_category_array_push_move(&budget.categories, first) == BWResult_OK);

  BWCategory second;
  assert(bw_category_init(&second, "Rent", 1000, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
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

void test_budget_add_transaction() {
  BWBudget budget;
  assert(bw_budget_init(&budget, "January") == BWResult_OK);

  BWCategory category;
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  category.id = 2;
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);

  BWTransaction existing;
  assert(bw_transaction_init(&existing, "Coffee", "Morning", test_date(), 5) == BWResult_OK);
  existing.id = 7;
  assert(bw_category_add_transaction(&budget.categories.items[0], existing) == BWResult_OK);

  BWTransaction transaction;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125) == BWResult_OK);
  assert(bw_budget_add_transaction(&budget, 2, transaction) == BWResult_OK);

  assert(budget.categories.items[0].transactions.length == 2);
  assert(budget.categories.items[0].transactions.items[1].id == 8);
  assert(budget.categories.items[0].amount_actual == 130);

  bw_budget_free(&budget);
  printf("(Pass) budget_add_transaction\n");
}

void test_budget_update_transaction_same_category() {
  BWBudget budget;
  assert(bw_budget_init(&budget, "January") == BWResult_OK);

  BWCategory category;
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  category.id = 2;

  BWTransaction transaction;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125) == BWResult_OK);
  transaction.id = 8;
  assert(bw_category_add_transaction(&category, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, category) == BWResult_OK);

  BWDate updated_date;
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

  bw_budget_free(&budget);
  printf("(Pass) budget_update_transaction_same_category\n");
}

void test_budget_update_transaction_move_category() {
  BWBudget budget;
  assert(bw_budget_init(&budget, "January") == BWResult_OK);

  BWCategory source;
  assert(bw_category_init(&source, "Food", 500, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  source.id = 2;

  BWTransaction transaction;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125) == BWResult_OK);
  transaction.id = 8;
  assert(bw_category_add_transaction(&source, transaction) == BWResult_OK);
  assert(bw_category_array_push_move(&budget.categories, source) == BWResult_OK);

  BWCategory target;
  assert(bw_category_init(&target, "Savings", 500, 10, 250, CATEGORY_SAVINGS) == BWResult_OK);
  target.id = 3;
  assert(bw_category_array_push_move(&budget.categories, target) == BWResult_OK);

  BWDate updated_date;
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

void test_budget_remove_transaction() {
  BWBudget budget;
  assert(bw_budget_init(&budget, "January") == BWResult_OK);

  BWCategory category;
  assert(bw_category_init(&category, "Food", 500, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  category.id = 2;

  BWTransaction transaction;
  assert(bw_transaction_init(&transaction, "Groceries", "Weekly shop", test_date(), 125) == BWResult_OK);
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

void test_budget_reorder_categories() {
  BWBudget budget;
  assert(bw_budget_init(&budget, "January") == BWResult_OK);

  BWCategory first;
  assert(bw_category_init(&first, "First", 100, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  first.id = 1;
  first.ordinal = 0;
  assert(bw_category_array_push_move(&budget.categories, first) == BWResult_OK);

  BWCategory second;
  assert(bw_category_init(&second, "Second", 100, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  second.id = 2;
  second.ordinal = 1;
  assert(bw_category_array_push_move(&budget.categories, second) == BWResult_OK);

  BWCategory third;
  assert(bw_category_init(&third, "Third", 100, 0, 0, CATEGORY_EXPENSES) == BWResult_OK);
  third.id = 3;
  third.ordinal = 2;
  assert(bw_category_array_push_move(&budget.categories, third) == BWResult_OK);

  BWCategory income;
  assert(bw_category_init(&income, "Income", 100, 0, 0, CATEGORY_INCOME) == BWResult_OK);
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

void test_json_failure_invalid_text() {
  BWBudget budget;
  assert(bw_budget_from_json_str(&budget, "{\"title\"") == BWResult_ERR);
  printf("(Pass) json_failure_invalid_text\n");
}

void test_json_failure_missing_required_fields() {
  cJSON *json = cJSON_Parse("{}");
  assert(json != NULL);

  BWTransaction transaction;
  assert(bw_transaction_from_json(&transaction, json) == BWResult_ERR);

  cJSON_Delete(json);
  printf("(Pass) json_failure_missing_required_fields\n");
}

void test_json_failure_invalid_date() {
  cJSON *json = cJSON_Parse("{\"id\":1,\"title\":\"x\",\"description\":\"y\",\"date\":\"2026/02/03\",\"amount\":1}");
  assert(json != NULL);

  BWTransaction transaction;
  assert(bw_transaction_from_json(&transaction, json) == BWResult_ERR);

  cJSON_Delete(json);
  printf("(Pass) json_failure_invalid_date\n");
}

void test_json_failure_invalid_category_type() {
  cJSON *json = cJSON_Parse("{\"id\":1,\"title\":\"x\",\"amount_planned\":1,\"amount_actual\":1,\"amount_accumulated\":0,\"category_type\":\"other\",\"transactions\":[]}");
  assert(json != NULL);

  BWCategory category;
  assert(bw_category_from_json(&category, json) == BWResult_ERR);

  cJSON_Delete(json);
  printf("(Pass) json_failure_invalid_category_type\n");
}

void test_json_failure_invalid_accumulated() {
  cJSON *json = cJSON_Parse("{\"id\":1,\"title\":\"x\",\"amount_planned\":1,\"amount_actual\":1,\"amount_accumulated\":1,\"category_type\":\"income\",\"transactions\":[]}");
  assert(json != NULL);

  BWCategory category;
  assert(bw_category_from_json(&category, json) == BWResult_ERR);

  cJSON_Delete(json);
  printf("(Pass) json_failure_invalid_accumulated\n");
}

void test_json_failure_large_amount() {
  cJSON *json = cJSON_Parse("{\"id\":1,\"title\":\"x\",\"description\":\"y\",\"date\":\"2026-01-31\",\"amount\":9007199254740992}");
  assert(json != NULL);

  BWTransaction transaction;
  assert(bw_transaction_from_json(&transaction, json) == BWResult_ERR);

  cJSON_Delete(json);
  printf("(Pass) json_failure_large_amount\n");
}

int main() {
  test_date_init();
  test_date_to_string();
  test_date_from_string();
  test_date_from_string_invalid();
  test_budget_init();
  test_category_init();
  test_category_init_with_accumulated();
  test_transaction_init();
  test_transaction_json_round_trip();
  test_transaction_array_push_move();
  test_category_array_push_move();
  test_category_json_round_trip();
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
