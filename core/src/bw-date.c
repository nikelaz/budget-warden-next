#include "bw-date.h"
#include "bw-string.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>

BWResult bw_date_init(BWDate *date, int year, int month, int day)
{
  if (date == NULL)
  {
    return BWResult_ERR;
  }
  date->year = year;
  date->month = month;
  date->day = day;
  return BWResult_OK;
}

BWString bw_date_to_string(const BWDate *date, BWArena *arena)
{
  BWString date_str = {0};
  
  if (date == NULL || bw_string_init(&date_str, arena) == BWResult_ERR)
  {
    return date_str;
  }

  char year_str[5];
  snprintf(year_str, sizeof(year_str), "%d", date->year);

  bw_string_append(&date_str, year_str);
  bw_string_append(&date_str, "-");

  int month = date->month;
  char month_str[3];
  snprintf(month_str, sizeof(month_str), "%d", month);

  if (month < 10)
  {
    bw_string_append(&date_str, "0");
  }

  bw_string_append(&date_str, month_str);
  bw_string_append(&date_str, "-");

  int day = date->day;
  char day_str[3];
  snprintf(day_str, sizeof(day_str), "%d", day);

  if (day < 10)
  {
    bw_string_append(&date_str, "0");
  }

  bw_string_append(&date_str, day_str);

  return date_str;
}

BWResult bw_date_from_string(BWDate *date, const char *date_str)
{
  if (date == NULL || date_str == NULL)
  {
    return BWResult_ERR;
  }

  if (strlen(date_str) != 10)
  {
    return BWResult_ERR;
  }

  if (
    !isdigit((unsigned char)date_str[0]) ||
    !isdigit((unsigned char)date_str[1]) ||
    !isdigit((unsigned char)date_str[2]) ||
    !isdigit((unsigned char)date_str[3]) ||
    date_str[4] != '-' ||
    !isdigit((unsigned char)date_str[5]) ||
    !isdigit((unsigned char)date_str[6]) ||
    date_str[7] != '-' ||
    !isdigit((unsigned char)date_str[8]) ||
    !isdigit((unsigned char)date_str[9])
  )
  {
    return BWResult_ERR;
  }

  int year =
    (date_str[0] - '0') * 1000 +
    (date_str[1] - '0') * 100 +
    (date_str[2] - '0') * 10 +
    (date_str[3] - '0');
  int month = (date_str[5] - '0') * 10 + (date_str[6] - '0');
  int day = (date_str[8] - '0') * 10 + (date_str[9] - '0');

  BWDate parsed;

  if (bw_date_init(&parsed, year, month, day) == BWResult_ERR)
  {
    return BWResult_ERR;
  }

  *date = parsed;
  return BWResult_OK;
}
