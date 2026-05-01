#ifndef BUDGET_H
#define BUDGET_H

#include "bwstring.h"
#include "bwdate.h"
#include "result.h"
#include "category.h"
#include "cjson.h"

typedef struct {
  BWString title;
  BWDate period_start;
  BWDate period_end;
  CategoryArray categories;
} Budget;

result budget_init(Budget *budget, const char* title, BWDate period_start, BWDate period_end);
void budget_free(Budget* budget);
cJSON *budget_to_json(Budget *budget);
BWString budget_to_json_str(Budget *budget);
result budget_from_json(Budget *budget, cJSON *json);
result budget_from_json_str(Budget *budget, const char* budget_json);

#endif
