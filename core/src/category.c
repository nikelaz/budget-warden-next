#include "category.h"

result category_init(
  Category *category,
  const char *title,
  uint64_t amount_planned,
  uint64_t amount_actual
)
{
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

  category->title = title_str;
  category->amount_planned = amount_planned;
  category->amount_actual = amount_actual;
  return ok;
}

void category_free(Category *category) {
  bw_string_free(&category->title);
}
