package com.lazarovco.budgetwarden.domain

import com.lazarovco.budgetwarden.core.BWBudget
import com.lazarovco.budgetwarden.core.BWCategory
import com.lazarovco.budgetwarden.core.BWCategoryType
import com.lazarovco.budgetwarden.core.BWDate
import com.lazarovco.budgetwarden.core.BWMoneyAmount
import com.lazarovco.budgetwarden.core.BWTransaction
import com.lazarovco.budgetwarden.core.formatMoneyInput
import com.lazarovco.budgetwarden.core.parseMoneyAmount
import java.text.NumberFormat
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Currency
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.absoluteValue

typealias Budget = BWBudget
typealias Category = BWCategory
typealias CategoryType = BWCategoryType
typealias Transaction = BWTransaction

val CategoryType.rawValue: Int
    get() = value

val CategoryType.title: String
    get() = this.title()

enum class TemplateSelection(val title: String) {
    BASIC("Monthly Budget"),
    BLANK("Empty Budget"),
    PREVIOUS("Previous budget"),
}

enum class AmountMode(val title: String) {
    PLANNED("Planned"),
    ACTUAL("Actual");

    fun amount(category: Category): Long = when (this) {
        PLANNED -> category.amountPlanned.value
        ACTUAL -> category.amountActual.value
    }
}

data class TransactionListItem(
    val category: Category,
    val transaction: Transaction,
)

object Money {
    fun parse(text: String, emptyValue: Long? = null): Long? =
        parseMoneyAmount(text = text, emptyValue = emptyValue)?.value

    fun inputText(amount: Long): String =
        formatMoneyInput(BWMoneyAmount(amount))

    fun format(amount: Long, currencyCode: String): String {
        val formatter = NumberFormat.getCurrencyInstance()
        formatter.currency = runCatching { Currency.getInstance(currencyCode) }.getOrNull()
        return formatter.format(amount.toDouble() / 100.0)
    }

    fun formatSigned(amount: Long, currencyCode: String): String {
        val prefix = if (amount < 0) "-" else ""
        return prefix + format(amount.absoluteValue, currencyCode)
    }
}

object BudgetDates {
    private val dayFormatter = SimpleDateFormat("yyyy-MM-dd", Locale.US).apply {
        isLenient = false
    }

    fun inputText(date: BWDate): String =
        "%04d-%02d-%02d".format(Locale.US, date.year, date.month, date.day)

    fun parseInput(value: String): BWDate? =
        runCatching {
            val parsed = dayFormatter.parse(value.trim()) ?: return null
            fromDate(parsed)
        }.getOrNull()

    fun displayText(date: BWDate): String =
        java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(toDate(date))

    fun toEpochMilliseconds(date: BWDate): Long = Calendar.getInstance(UTC).apply {
        clear()
        set(date.year, date.month - 1, date.day)
    }.timeInMillis

    fun fromEpochMilliseconds(value: Long): BWDate {
        val calendar = Calendar.getInstance(UTC).apply { timeInMillis = value }
        return BWDate(
            year = calendar.get(Calendar.YEAR),
            month = calendar.get(Calendar.MONTH) + 1,
            day = calendar.get(Calendar.DAY_OF_MONTH),
        )
    }

    private fun fromDate(date: Date): BWDate {
        val calendar = Calendar.getInstance().apply { time = date }
        return BWDate(
            year = calendar.get(Calendar.YEAR),
            month = calendar.get(Calendar.MONTH) + 1,
            day = calendar.get(Calendar.DAY_OF_MONTH),
        )
    }

    private fun toDate(date: BWDate): Date = Calendar.getInstance().apply {
        clear()
        set(date.year, date.month - 1, date.day)
    }.time

    private val UTC: TimeZone = TimeZone.getTimeZone("UTC")
}
