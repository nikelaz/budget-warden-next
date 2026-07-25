package com.lazarovco.budgetwarden.domain

import java.text.NumberFormat
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Currency
import java.util.Date
import java.util.Locale
import java.util.UUID
import kotlin.math.absoluteValue

enum class CategoryType(val rawValue: Int, val title: String) {
    INCOME(1, "Income"),
    EXPENSES(2, "Expenses"),
    SAVINGS(3, "Savings"),
    DEBT(4, "Debt");

    companion object {
        fun fromRawValue(value: Int): CategoryType =
            entries.firstOrNull { it.rawValue == value } ?: EXPENSES
    }
}

data class Transaction(
    val id: String = UUID.randomUUID().toString(),
    val title: String,
    val description: String = "",
    val date: Date = Date(),
    val amount: Long = 0L,
)

data class Category(
    val id: String = UUID.randomUUID().toString(),
    val ordinal: Int = 0,
    val title: String,
    val amountPlanned: Long = 0L,
    val amountActual: Long = 0L,
    val amountAccumulated: Long = 0L,
    val categoryType: CategoryType,
    val transactions: List<Transaction> = emptyList(),
) {
    fun cloneAsTemplate(): Category = copy(
        id = UUID.randomUUID().toString(),
        amountActual = 0L,
        transactions = emptyList(),
    )
}

data class Budget(
    val id: String = UUID.randomUUID().toString(),
    val revision: Long = 1L,
    val schemaVersion: Int = 1,
    val title: String,
    val categories: List<Category> = emptyList(),
    val fileName: String? = null,
    val crdt: BudgetCrdtState? = null,
) {
    fun orderedCategories(type: CategoryType? = null): List<Category> =
        categories
            .withIndex()
            .filter { (_, category) -> type == null || category.categoryType == type }
            .sortedWith(
                compareBy<IndexedValue<Category>> { it.value.categoryType.rawValue }
                    .thenBy { it.value.ordinal }
                    .thenBy { it.index },
            )
            .map { it.value }

    fun cloneAsTemplate(newTitle: String): Budget = Budget(
        title = newTitle,
        categories = categories.map { it.cloneAsTemplate() },
    )
}

enum class TemplateSelection(val title: String) {
    BASIC("Basic"),
    BLANK("Blank"),
    PREVIOUS("Previous budget"),
}

enum class AmountMode(val title: String) {
    PLANNED("Planned"),
    ACTUAL("Actual");

    fun amount(category: Category): Long =
        if (this == PLANNED) category.amountPlanned else category.amountActual
}

data class TransactionListItem(
    val category: Category,
    val transaction: Transaction,
)

object Money {
    fun parse(text: String, emptyValue: Long? = null): Long? {
        val trimmed = text.trim()
        if (trimmed.isEmpty()) return emptyValue

        val normalized = trimmed.replace(',', '.')
        val parts = normalized.split('.', limit = 2)
        if (parts.size > 2) return null

        val whole = parts[0]
        val fraction = parts.getOrNull(1)
        if (whole.isEmpty() && fraction == null) return null
        if (whole.any { !it.isDigit() }) return null
        if (fraction != null && (fraction.length !in 1..2 || fraction.any { !it.isDigit() })) {
            return null
        }

        val wholeAmount = whole.toLongOrNull() ?: 0L
        val cents = when {
            fraction == null -> 0L
            fraction.length == 1 -> (fraction.toLongOrNull() ?: return null) * 10L
            else -> fraction.toLongOrNull() ?: return null
        }

        return try {
            Math.addExact(Math.multiplyExact(wholeAmount, 100L), cents)
        } catch (_: ArithmeticException) {
            null
        }
    }

    fun inputText(amount: Long): String {
        val whole = amount / 100L
        val fraction = amount % 100L
        return "$whole.${fraction.toString().padStart(2, '0')}"
    }

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
    private val isoFormatter = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US).apply {
        timeZone = java.util.TimeZone.getTimeZone("UTC")
    }

    private val dayFormatter = SimpleDateFormat("yyyy-MM-dd", Locale.US)

    fun encode(date: Date): String = isoFormatter.format(date)

    fun decode(value: String): Date =
        try {
            isoFormatter.parse(value) ?: Date()
        } catch (_: ParseException) {
            try {
                dayFormatter.parse(value) ?: Date()
            } catch (_: ParseException) {
                Date()
            }
        }

    fun inputText(date: Date): String = dayFormatter.format(date)

    fun parseInput(value: String): Date? =
        try {
            dayFormatter.parse(value.trim())
        } catch (_: ParseException) {
            null
        }

    fun displayText(date: Date): String =
        java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM).format(date)
}

object BudgetTemplates {
    fun basicBudget(title: String): Budget = Budget(
        title = title,
        categories = listOf(
            Category(title = "Salary", amountPlanned = 480000, categoryType = CategoryType.INCOME),
            Category(ordinal = 0, title = "Fun & Entertainment", amountPlanned = 20000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 1, title = "Health & Fitness", amountPlanned = 15000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 2, title = "Giving", amountPlanned = 24000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 3, title = "Utilities", amountPlanned = 28000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 4, title = "Miscellaneous", amountPlanned = 15000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 5, title = "Insurance", amountPlanned = 30000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 6, title = "Housing", amountPlanned = 120000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 7, title = "Food", amountPlanned = 64000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 8, title = "Personal Care", amountPlanned = 18000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 9, title = "Transportation", amountPlanned = 24000, categoryType = CategoryType.EXPENSES),
            Category(ordinal = 0, title = "Emergency Fund", amountPlanned = 50000, categoryType = CategoryType.SAVINGS),
            Category(ordinal = 1, title = "Retirement", amountPlanned = 72000, categoryType = CategoryType.SAVINGS),
        ),
    )
}

object ReportingSummary {
    fun total(budget: Budget, types: Set<CategoryType>, mode: AmountMode): Long =
        budget.categories
            .filter { it.categoryType in types }
            .sumOf { mode.amount(it) }

    fun incomeTotal(budget: Budget): Long =
        budget.categories.filter { it.categoryType == CategoryType.INCOME }.sumOf { it.amountPlanned }

    fun plannedSpendingTotal(budget: Budget): Long =
        total(budget, setOf(CategoryType.EXPENSES, CategoryType.DEBT), AmountMode.PLANNED)

    fun actualSpendingTotal(budget: Budget): Long =
        total(budget, setOf(CategoryType.EXPENSES, CategoryType.DEBT), AmountMode.ACTUAL)

    fun plannedSavingsTotal(budget: Budget): Long =
        total(budget, setOf(CategoryType.SAVINGS), AmountMode.PLANNED)

    fun leftToBudgetTotal(budget: Budget): Long =
        incomeTotal(budget) - plannedSpendingTotal(budget) - plannedSavingsTotal(budget)

    fun allocationSegments(budget: Budget, mode: AmountMode): List<Pair<String, Long>> =
        listOf(
            "Expenses" to total(budget, setOf(CategoryType.EXPENSES), mode),
            "Savings" to total(budget, setOf(CategoryType.SAVINGS), mode),
            "Debt" to total(budget, setOf(CategoryType.DEBT), mode),
        ).filter { it.second > 0L }

    fun categorySegments(budget: Budget, type: CategoryType, mode: AmountMode): List<Pair<String, Long>> =
        budget.orderedCategories(type)
            .map { it.title to mode.amount(it) }
            .filter { it.second > 0L }
}
