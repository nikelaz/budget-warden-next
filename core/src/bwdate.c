#include "bwdate.h"
#include "bwstring.h"
#include <ctype.h>
#include <stdio.h>
#include <string.h>

result bw_date_init(BWDate *date, int year, int month, int day)
{
    struct tm tm_date = {0};

    tm_date.tm_year = year - 1900;
    tm_date.tm_mon = month - 1;
    tm_date.tm_mday = day;

    tm_date.tm_hour = 12;

    time_t timestamp = mktime(&tm_date);

    if (timestamp == (time_t)-1) {
        return err;
    }

    date->timestamp = timestamp;
    return ok;
}

int bw_date_get_year(const BWDate *date)
{
    struct tm *tm_date = localtime(&date->timestamp);

    if (tm_date == NULL) {
        return 0;
    }

    return tm_date->tm_year + 1900;
}

int bw_date_get_month(const BWDate *date)
{
    struct tm *tm_date = localtime(&date->timestamp);

    if (tm_date == NULL) {
        return 0;
    }

    return tm_date->tm_mon + 1;
}

int bw_date_get_day(const BWDate *date)
{
    struct tm *tm_date = localtime(&date->timestamp);

    if (tm_date == NULL) {
        return 0;
    }

    return tm_date->tm_mday;
}

BWString bw_date_to_string(const BWDate *date)
{
  BWString date_str;
  
  bw_string_init(&date_str);

  char year_str[5];
  snprintf(year_str, sizeof(year_str), "%d", bw_date_get_year(date));

  bw_string_append(&date_str, year_str);
  bw_string_append(&date_str, "-");

  int month = bw_date_get_month(date);
  char month_str[3];
  snprintf(month_str, sizeof(month_str), "%d", month);

  if (month < 10)
  {
    bw_string_append(&date_str, "0");
  }

  bw_string_append(&date_str, month_str);
  bw_string_append(&date_str, "-");

  int day = bw_date_get_day(date);
  char day_str[3];
  snprintf(day_str, sizeof(day_str), "%d", day);

  if (day < 10)
  {
    bw_string_append(&date_str, "0");
  }

  bw_string_append(&date_str, day_str);

  return date_str;
}

result bw_date_from_string(BWDate *date, const char *date_str)
{
  if (date == NULL || date_str == NULL)
  {
    return err;
  }

  if (strlen(date_str) != 10)
  {
    return err;
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
    return err;
  }

  int year =
    (date_str[0] - '0') * 1000 +
    (date_str[1] - '0') * 100 +
    (date_str[2] - '0') * 10 +
    (date_str[3] - '0');
  int month = (date_str[5] - '0') * 10 + (date_str[6] - '0');
  int day = (date_str[8] - '0') * 10 + (date_str[9] - '0');

  BWDate parsed;

  if (bw_date_init(&parsed, year, month, day) == err)
  {
    return err;
  }

  if (
    bw_date_get_year(&parsed) != year ||
    bw_date_get_month(&parsed) != month ||
    bw_date_get_day(&parsed) != day
  )
  {
    return err;
  }

  *date = parsed;
  return ok;
}
