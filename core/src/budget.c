#include "budget.h"

result budget_init(
    Budget *budget,
    const char *title,
    BWDate period_start,
    BWDate period_end
)
{
  if (budget == NULL || title == NULL)
  {
    return err;
  }

  BWString title_str;

  if (bw_string_init(&title_str) == err)
  {
    return err;
  }

  if (bw_string_append(&title_str, title) == err)
  {
    bw_string_free(&title_str);
    return err;
  }

  CategoryArray categories;

  if (category_array_init(&categories) == err)
  {
    bw_string_free(&title_str);
    return err;
  }

  budget->title = title_str;
  budget->period_start = period_start;
  budget->period_end = period_end;
  budget->categories = categories;
  return ok;
}

void budget_free(Budget *budget)
{
  category_array_free(&budget->categories);
  bw_string_free(&budget->title);
}
