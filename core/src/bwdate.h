#ifndef DATE_H
#define DATE_H

#include <time.h>

typedef struct {
    time_t timestamp;
} BWDate;

int bw_date_init(BWDate *date, int year, int month, int day);
int bw_date_get_year(const BWDate *date);
int bw_date_get_month(const BWDate *date);
int bw_date_get_day(const BWDate *date);

#endif
