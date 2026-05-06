#ifndef BW_DATE_H
#define BW_DATE_H

#include <time.h>
#include "bw-string.h"
#include "bw-result.h"

typedef struct {
  int year;
  int month;
  int day;
} BWDate;

BWResult bw_date_init(BWDate *date, int year, int month, int day);
int bw_date_get_year(const BWDate *date);
int bw_date_get_month(const BWDate *date);
int bw_date_get_day(const BWDate *date);
BWString bw_date_to_string(const BWDate *date, BWArena *arena);
BWResult bw_date_from_string(BWDate *date, const char *date_str);

#endif
