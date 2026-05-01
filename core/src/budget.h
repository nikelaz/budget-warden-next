#ifndef BUDGET_H
#define BUDGET_H

#include "bwstring.h"
#include "bwdate.h"
#include "result.h"
#include "category.h"

typedef struct {
  BWString title;
  BWDate period_start;
  BWDate period_end;
  CategoryArray categories;
} Budget;

result budget_init(Budget *budget, const char* title, BWDate period_start, BWDate period_end);
void budget_free(Budget* budget);

#endif
