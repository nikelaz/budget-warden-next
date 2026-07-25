package com.lazarovco.budgetwarden.domain

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BudgetRebaseTest {
    private val diskTransaction = Transaction(id = "tx-disk", title = "Disk", amount = 100)
    private val diskCategory = Category(id = "cat-a", title = "Disk category", categoryType = CategoryType.EXPENSES, transactions = listOf(diskTransaction))
    private val otherCategory = Category(id = "cat-b", title = "Other", categoryType = CategoryType.SAVINGS)
    private val disk = Budget(id = "budget", revision = 4, title = "Disk title", categories = listOf(diskCategory, otherCategory))

    @Test fun identicalRevisionReturnsMemoryUnchanged() {
        val memory = disk.copy(title = "Memory")
        assertEquals(memory, BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.BudgetUpdate))
    }

    @Test fun budgetUpdateChangesOnlyTitle() {
        val memory = disk.copy(revision = 3, title = "Memory", categories = emptyList())
        assertEquals(disk.copy(title = "Memory"), BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.BudgetUpdate))
    }

    @Test fun categoryCreateAppendsWithNextTypeOrdinal() {
        val created = Category(id = "cat-new", ordinal = 99, title = "New", categoryType = CategoryType.EXPENSES)
        val result = BudgetRebase.rebase(disk.copy(revision = 3, categories = disk.categories + created), disk, BudgetRebaseOperation.CategoryCreate(created.id))
        assertEquals(1, result.categories.first { it.id == created.id }.ordinal)
        assertTrue(result.categories.any { it.id == otherCategory.id })
    }

    @Test fun categoryUpdateReplacesOrRestoresCategory() {
        val updated = diskCategory.copy(title = "Updated")
        val memory = disk.copy(revision = 3, categories = listOf(updated))
        assertEquals(updated, BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.CategoryUpdate(updated.id)).categories.first())
        val deletedOnDisk = disk.copy(categories = listOf(otherCategory))
        assertTrue(BudgetRebase.rebase(memory, deletedOnDisk, BudgetRebaseOperation.CategoryUpdate(updated.id)).categories.contains(updated))
    }

    @Test fun categoryDeletePreservesUnrelatedDiskChanges() {
        val changedOther = otherCategory.copy(title = "Changed elsewhere")
        val latestDisk = disk.copy(categories = listOf(diskCategory, changedOther))
        val result = BudgetRebase.rebase(disk.copy(revision = 3, categories = listOf(otherCategory)), latestDisk, BudgetRebaseOperation.CategoryDelete(diskCategory.id))
        assertEquals(listOf(changedOther), result.categories)
    }

    @Test fun bulkOrdinalUpdateTouchesOnlyListedCategories() {
        val reordered = diskCategory.copy(ordinal = 7)
        val changedOther = otherCategory.copy(title = "Remote")
        val result = BudgetRebase.rebase(
            disk.copy(revision = 3, categories = listOf(reordered, otherCategory)),
            disk.copy(categories = listOf(diskCategory, changedOther)),
            BudgetRebaseOperation.CategoriesBulkOrdinalUpdate(listOf(diskCategory.id)),
        )
        assertEquals(reordered, result.categories[0])
        assertEquals(changedOther, result.categories[1])
    }

    @Test fun transactionCreateIsIdempotentAndRestoresMissingCategory() {
        val created = Transaction(id = "tx-new", title = "New", amount = 200)
        val memoryCategory = diskCategory.copy(transactions = diskCategory.transactions + created)
        val memory = disk.copy(revision = 3, categories = listOf(memoryCategory, otherCategory))
        val result = BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.TransactionCreate(diskCategory.id, created.id))
        assertEquals(1, result.categories.first().transactions.count { it.id == created.id })
        val restored = BudgetRebase.rebase(memory, disk.copy(categories = listOf(otherCategory)), BudgetRebaseOperation.TransactionCreate(diskCategory.id, created.id))
        assertTrue(restored.categories.any { it.id == diskCategory.id })
    }

    @Test fun transactionUpdateCanMoveBetweenCategories() {
        val updated = diskTransaction.copy(title = "Moved")
        val memory = disk.copy(revision = 3, categories = listOf(diskCategory.copy(transactions = emptyList()), otherCategory.copy(transactions = listOf(updated))))
        val result = BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.TransactionUpdate(diskCategory.id, otherCategory.id, updated.id))
        assertFalse(result.categories.first { it.id == diskCategory.id }.transactions.any { it.id == updated.id })
        assertEquals(updated, result.categories.first { it.id == otherCategory.id }.transactions.single())
    }

    @Test fun transactionDeleteFindsTransactionMovedRemotely() {
        val movedDisk = disk.copy(categories = listOf(diskCategory.copy(transactions = emptyList()), otherCategory.copy(transactions = listOf(diskTransaction))))
        val result = BudgetRebase.rebase(disk.copy(revision = 3), movedDisk, BudgetRebaseOperation.TransactionDelete(diskCategory.id, diskTransaction.id))
        assertTrue(result.categories.all { category -> category.transactions.none { it.id == diskTransaction.id } })
    }

    @Test fun otherUsesMemoryAndCreateIgnoresDisk() {
        val memory = disk.copy(revision = 3, title = "Memory")
        assertEquals(memory, BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.Other))
        assertEquals(memory, BudgetRebase.rebase(memory, disk, BudgetRebaseOperation.BudgetCreate))
    }
}
