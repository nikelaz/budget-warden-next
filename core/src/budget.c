#include "budget.h"

static cJSON *json_get_string(cJSON *json, const char *name)
{
  cJSON *item = cJSON_GetObjectItemCaseSensitive(json, name);

  if (!cJSON_IsString(item) || item->valuestring == NULL)
  {
    return NULL;
  }

  return item;
}

result budget_init(
    Budget *budget,
    const char *title
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
  budget->categories = categories;
  return ok;
}

void budget_free(Budget *budget)
{
  category_array_free(&budget->categories);
  bw_string_free(&budget->title);
}

cJSON *budget_to_json(Budget *budget)
{
  if (budget == NULL)
  {
    return NULL;
  }

  cJSON *json = cJSON_CreateObject();
  cJSON *categories = cJSON_CreateArray();

  if (json == NULL || categories == NULL)
  {
    cJSON_Delete(json);
    cJSON_Delete(categories);
    return NULL;
  }

  if (
    cJSON_AddStringToObject(json, "title", budget->title.data) == NULL ||
    !cJSON_AddItemToObject(json, "categories", categories)
  )
  {
    cJSON_Delete(json);
    cJSON_Delete(categories);
    return NULL;
  }

  categories = NULL;

  for (size_t i = 0; i < budget->categories.length; i++)
  {
    cJSON *category = category_to_json(&budget->categories.items[i]);

    if (category == NULL || !cJSON_AddItemToArray(cJSON_GetObjectItemCaseSensitive(json, "categories"), category))
    {
      cJSON_Delete(category);
      cJSON_Delete(json);
      return NULL;
    }
  }

  return json;
}

BWString budget_to_json_str(Budget *budget)
{
  BWString budget_json;
  bw_string_init(&budget_json);

  cJSON *json = budget_to_json(budget);

  if (json == NULL)
  {
    return budget_json;
  }

  char *printed = cJSON_PrintUnformatted(json);

  if (printed != NULL)
  {
    bw_string_append(&budget_json, printed);
    cJSON_free(printed);
  }

  cJSON_Delete(json);
  return budget_json;
}

result budget_from_json(Budget *budget, cJSON *json)
{
  if (budget == NULL || !cJSON_IsObject(json))
  {
    return err;
  }

  cJSON *title = json_get_string(json, "title");
  cJSON *categories = cJSON_GetObjectItemCaseSensitive(json, "categories");

  if (
    title == NULL ||
    !cJSON_IsArray(categories) ||
    budget_init(budget, title->valuestring) == err
  )
  {
    return err;
  }

  cJSON *category_json = NULL;
  cJSON_ArrayForEach(category_json, categories)
  {
    Category category = {0};

    if (
      category_from_json(&category, category_json) == err ||
      category_array_push_move(&budget->categories, category) == err
    )
    {
      if (category.title.data != NULL)
      {
        category_free(&category);
      }

      budget_free(budget);
      return err;
    }
  }

  return ok;
}

result budget_from_json_str(Budget *budget, const char *budget_json)
{
  if (budget == NULL || budget_json == NULL)
  {
    return err;
  }

  cJSON *json = cJSON_Parse(budget_json);

  if (json == NULL)
  {
    return err;
  }

  result res = budget_from_json(budget, json);
  cJSON_Delete(json);
  return res;
}
