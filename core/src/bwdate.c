#include "bwdate.h"
#include "result.h"

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
