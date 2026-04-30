#include "budget.h"

result budget_create(
    Budget *budget,
    const char *title,
    Date period_start,
    Date period_end
)
{
  if (budget == NULL || title == NULL)
  {
    return err;
  }

  String title_str; 
  
  if (string_init(&title_str) == err)
  {
    return err;
  }

  if (string_append(&title_str, title) == err)
  {
    string_free(&title_str);
    return err;
  }

  budget->title = title_str;
  budget->period_start = period_start;
  budget->period_end = period_end;
  return ok;
}

void budget_free(Budget *budget)
{
  string_free(&budget->title);
}
