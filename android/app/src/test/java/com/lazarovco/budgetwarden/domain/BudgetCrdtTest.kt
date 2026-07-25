package com.lazarovco.budgetwarden.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Date

class BudgetCrdtTest {
    @Test
    fun concurrentDeleteWinsOverEdit() {
        val transaction = Transaction(id = "transaction", title = "Payment", date = Date(1), amount = 100)
        val category = Category(id = "category", title = "Rent", categoryType = CategoryType.EXPENSES, transactions = listOf(transaction))
        val base = BudgetCrdt.migrateLegacy(Budget(id = "budget", title = "Budget", categories = listOf(category)))
        val baseState = requireNotNull(base.crdt)
        val deleteStamp = stamp("delete")
        val editStamp = stamp("edit")
        val deleted = base.copy(crdt = baseState.copy(
            versionVector = baseState.versionVector + ("delete" to 1L),
            transactions = baseState.transactions + ("transaction" to requireNotNull(baseState.transactions["transaction"]).copy(
                presence = CrdtRegister(false, deleteStamp),
            )),
        ))
        val editedTransaction = requireNotNull(baseState.transactions["transaction"])
        val edited = base.copy(crdt = baseState.copy(
            versionVector = baseState.versionVector + ("edit" to 1L),
            transactions = baseState.transactions + ("transaction" to editedTransaction.copy(
                presence = CrdtRegister(true, editStamp),
                amount = CrdtRegister(999L, editStamp),
            )),
        ))

        val merged = BudgetCrdt.merge(deleted, edited)
        assertTrue(merged.categories.single().transactions.isEmpty())
        assertEquals(false, merged.crdt?.transactions?.get("transaction")?.presence?.value)
    }

    @Test
    fun higherLegacyRevisionWinsWholeSnapshot() {
        val older = BudgetCrdt.migrateLegacy(Budget(id = "budget", revision = 1, title = "Older"))
        val newer = BudgetCrdt.migrateLegacy(Budget(id = "budget", revision = 2, title = "Newer"))

        assertEquals("Newer", BudgetCrdt.merge(older, newer).title)
        assertEquals("Newer", BudgetCrdt.merge(newer, older).title)
    }

    private fun stamp(actor: String) = CrdtStamp(actor, 1, emptyMap(), 1, 0)
}
