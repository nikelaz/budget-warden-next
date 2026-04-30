#ifndef DATE_H
#define DATE_H

#include <time.h>

typedef struct {
    time_t timestamp;
} Date;

int date_create(Date *date, int year, int month, int day);
int date_get_year(const Date *date);
int date_get_month(const Date *date);
int date_get_day(const Date *date);

#endif
