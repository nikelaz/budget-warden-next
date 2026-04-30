#ifndef BUDGET_H
#define BUDGET_H

#include "dynamic_string.h"
#include "date.h"
#include "result.h"

typedef struct {
  String title;
  Date period_start;
  Date period_end;
} Budget;

result budget_create(Budget *budget, const char* title, Date period_start, Date period_end);
void budget_free(Budget* budget);

#endif
