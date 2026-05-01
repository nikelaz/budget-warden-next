#ifndef DATE_H
#define DATE_H

#include <time.h>
#include "bwstring.h"
#include "result.h"

typedef struct {
    time_t timestamp;
} BWDate;

result bw_date_init(BWDate *date, int year, int month, int day);
int bw_date_get_year(const BWDate *date);
int bw_date_get_month(const BWDate *date);
int bw_date_get_day(const BWDate *date);
BWString bw_date_to_string(const BWDate *date);
result bw_date_from_string(BWDate *date, const char *date_str);

#endif
