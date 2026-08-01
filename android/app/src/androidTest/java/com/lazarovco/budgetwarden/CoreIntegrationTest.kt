package com.lazarovco.budgetwarden

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.lazarovco.budgetwarden.core.BWDate
import com.lazarovco.budgetwarden.core.BWMoneyAmount
import com.lazarovco.budgetwarden.core.BWTemplateType
import com.lazarovco.budgetwarden.core.buildReportingSummary
import com.lazarovco.budgetwarden.core.budgetFromTemplate
import com.lazarovco.budgetwarden.core.createTransaction
import com.lazarovco.budgetwarden.core.decodeBudget
import com.lazarovco.budgetwarden.core.encodeBudget
import com.lazarovco.budgetwarden.core.newTransaction
import com.lazarovco.budgetwarden.core.updateBudgetTitle
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class CoreIntegrationTest {
    @Test
    fun generatedBindingsRunTheBudgetWorkflow() {
        val original = budgetFromTemplate(BWTemplateType.BASIC_MONTHLY, "August Budget")
        val expenseCategory = original.categories.first { it.title == "Food" }
        val transaction = newTransaction(
            title = "Groceries",
            description = "Weekly shop",
            date = BWDate(year = 2026, month = 8, day = 1),
            amount = BWMoneyAmount(12_345),
        )
        val renamed = updateBudgetTitle(original, "Renamed August Budget")
        val updated = createTransaction(renamed, expenseCategory.id, transaction).updateActuals()
        val decoded = decodeBudget(encodeBudget(updated), "content://tests/august.budget")
        val reporting = buildReportingSummary(decoded)

        assertEquals("Renamed August Budget", decoded.title)
        assertEquals(
            12_345,
            decoded.categories.first { it.id == expenseCategory.id }.amountActual.value,
        )
        assertTrue(reporting.totals.actualSpending.value >= 12_345)
    }
}
