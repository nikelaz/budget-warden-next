package com.lazarovco.budgetwarden.domain

import org.json.JSONArray
import org.json.JSONObject

sealed interface BudgetRebaseOperation {
    data object BudgetCreate : BudgetRebaseOperation
    data object BudgetUpdate : BudgetRebaseOperation
    data class CategoryCreate(val categoryId: String) : BudgetRebaseOperation
    data class CategoryUpdate(val categoryId: String) : BudgetRebaseOperation
    data class CategoryDelete(val categoryId: String) : BudgetRebaseOperation
    data class CategoriesBulkOrdinalUpdate(val categoryIds: List<String>) : BudgetRebaseOperation
    data class TransactionCreate(val categoryId: String, val transactionId: String) : BudgetRebaseOperation
    data class TransactionUpdate(val sourceCategoryId: String, val destinationCategoryId: String, val transactionId: String) : BudgetRebaseOperation
    data class TransactionDelete(val categoryId: String, val transactionId: String) : BudgetRebaseOperation
    data object Other : BudgetRebaseOperation

    fun encode(): String = JSONObject().apply {
        when (val operation = this@BudgetRebaseOperation) {
            BudgetCreate -> put("type", "budgetCreate")
            BudgetUpdate -> put("type", "budgetUpdate")
            is CategoryCreate -> put("type", "categoryCreate").put("categoryId", operation.categoryId)
            is CategoryUpdate -> put("type", "categoryUpdate").put("categoryId", operation.categoryId)
            is CategoryDelete -> put("type", "categoryDelete").put("categoryId", operation.categoryId)
            is CategoriesBulkOrdinalUpdate -> put("type", "categoriesBulkOrdinalUpdate").put("categoryIds", JSONArray(operation.categoryIds))
            is TransactionCreate -> put("type", "transactionCreate").put("categoryId", operation.categoryId).put("transactionId", operation.transactionId)
            is TransactionUpdate -> put("type", "transactionUpdate").put("sourceCategoryId", operation.sourceCategoryId)
                .put("destinationCategoryId", operation.destinationCategoryId).put("transactionId", operation.transactionId)
            is TransactionDelete -> put("type", "transactionDelete").put("categoryId", operation.categoryId).put("transactionId", operation.transactionId)
            Other -> put("type", "other")
        }
    }.toString()

    companion object {
        fun decode(value: String?): BudgetRebaseOperation {
            if (value == null) return Other
            val json = JSONObject(value)
            return when (json.getString("type")) {
                "budgetCreate" -> BudgetCreate
                "budgetUpdate" -> BudgetUpdate
                "categoryCreate" -> CategoryCreate(json.getString("categoryId"))
                "categoryUpdate" -> CategoryUpdate(json.getString("categoryId"))
                "categoryDelete" -> CategoryDelete(json.getString("categoryId"))
                "categoriesBulkOrdinalUpdate" -> CategoriesBulkOrdinalUpdate(json.getJSONArray("categoryIds").let { array -> List(array.length()) { array.getString(it) } })
                "transactionCreate" -> TransactionCreate(json.getString("categoryId"), json.getString("transactionId"))
                "transactionUpdate" -> TransactionUpdate(json.getString("sourceCategoryId"), json.getString("destinationCategoryId"), json.getString("transactionId"))
                "transactionDelete" -> TransactionDelete(json.getString("categoryId"), json.getString("transactionId"))
                else -> Other
            }
        }
    }
}

object BudgetRebase {
    fun rebase(inMemory: Budget, onDisk: Budget, operation: BudgetRebaseOperation): Budget {
        if (inMemory.revision == onDisk.revision) return inMemory
        return when (operation) {
            BudgetRebaseOperation.BudgetCreate -> inMemory
            BudgetRebaseOperation.BudgetUpdate -> onDisk.copy(title = inMemory.title)
            is BudgetRebaseOperation.CategoryCreate -> {
                val category = inMemory.categories.firstOrNull { it.id == operation.categoryId }
                    ?: error("Rebase failed: created category is missing.")
                val ordinal = onDisk.categories.filter { it.categoryType == category.categoryType }.maxOfOrNull { it.ordinal }?.plus(1) ?: 0
                onDisk.copy(categories = onDisk.categories + category.copy(ordinal = ordinal))
            }
            is BudgetRebaseOperation.CategoryUpdate -> {
                val updated = inMemory.categories.firstOrNull { it.id == operation.categoryId }
                    ?: error("Rebase failed: updated category is missing.")
                onDisk.copy(categories = if (onDisk.categories.any { it.id == operation.categoryId }) {
                    onDisk.categories.map { if (it.id == operation.categoryId) updated else it }
                } else onDisk.categories + updated)
            }
            is BudgetRebaseOperation.CategoryDelete -> onDisk.copy(categories = onDisk.categories.filterNot { it.id == operation.categoryId })
            is BudgetRebaseOperation.CategoriesBulkOrdinalUpdate -> onDisk.copy(categories = onDisk.categories.map { diskCategory ->
                if (diskCategory.id in operation.categoryIds) inMemory.categories.firstOrNull { it.id == diskCategory.id } ?: diskCategory else diskCategory
            })
            is BudgetRebaseOperation.TransactionCreate -> {
                val memoryCategory = inMemory.categories.firstOrNull { it.id == operation.categoryId }
                    ?: error("Rebase failed: transaction category is missing.")
                val transaction = memoryCategory.transactions.firstOrNull { it.id == operation.transactionId }
                    ?: error("Rebase failed: created transaction is missing.")
                val categories = if (onDisk.categories.none { it.id == operation.categoryId }) onDisk.categories + memoryCategory else onDisk.categories
                onDisk.copy(categories = categories.map { category ->
                    if (category.id == operation.categoryId && category.transactions.none { it.id == operation.transactionId }) {
                        category.copy(transactions = category.transactions + transaction)
                    } else category
                })
            }
            is BudgetRebaseOperation.TransactionUpdate -> {
                val source = onDisk.categories.firstOrNull { it.id == operation.sourceCategoryId }
                    ?: error("Rebase failed: source category is missing.")
                check(onDisk.categories.any { it.id == operation.destinationCategoryId }) { "Rebase failed: destination category is missing." }
                check(source.transactions.any { it.id == operation.transactionId }) { "Rebase failed: transaction is missing." }
                val updated = inMemory.categories.firstOrNull { it.id == operation.destinationCategoryId }?.transactions?.firstOrNull { it.id == operation.transactionId }
                    ?: error("Rebase failed: updated transaction is missing.")
                onDisk.copy(categories = onDisk.categories.map { category ->
                    when {
                        operation.sourceCategoryId == operation.destinationCategoryId && category.id == operation.sourceCategoryId ->
                            category.copy(transactions = category.transactions.map { if (it.id == operation.transactionId) updated else it })
                        category.id == operation.sourceCategoryId -> category.copy(transactions = category.transactions.filterNot { it.id == operation.transactionId })
                        category.id == operation.destinationCategoryId -> category.copy(transactions = category.transactions + updated)
                        else -> category
                    }
                })
            }
            is BudgetRebaseOperation.TransactionDelete -> {
                val requestedCategory = onDisk.categories.firstOrNull { it.id == operation.categoryId }
                    ?: error("Rebase failed: category is missing.")
                val containingCategory = if (requestedCategory.transactions.any { it.id == operation.transactionId }) {
                    requestedCategory
                } else {
                    onDisk.categories.firstOrNull { category -> category.transactions.any { it.id == operation.transactionId } }
                        ?: error("Rebase failed: transaction is missing.")
                }
                onDisk.copy(categories = onDisk.categories.map { category ->
                    if (category.id == containingCategory.id) category.copy(transactions = category.transactions.filterNot { it.id == operation.transactionId }) else category
                })
            }
            BudgetRebaseOperation.Other -> inMemory
        }
    }
}
