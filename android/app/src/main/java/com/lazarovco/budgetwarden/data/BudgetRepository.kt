package com.lazarovco.budgetwarden.data

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import com.lazarovco.budgetwarden.BudgetWardenApplication
import com.lazarovco.budgetwarden.core.BWBudget
import com.lazarovco.budgetwarden.core.BWTemplateType
import com.lazarovco.budgetwarden.core.budgetFromPreviousBudget
import com.lazarovco.budgetwarden.core.budgetFromTemplate
import com.lazarovco.budgetwarden.core.decodeBudget
import com.lazarovco.budgetwarden.core.encodeBudget
import com.lazarovco.budgetwarden.core.mergeBudgetForSave
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.TemplateSelection
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

data class StoredBudget(
    val budget: Budget,
    val uri: Uri,
    val displayName: String,
)

internal interface BudgetDataSource {
    suspend fun loadStoredBudgets(): List<StoredBudget>

    suspend fun openBudget(uri: Uri): Budget

    suspend fun createBudget(
        uri: Uri,
        title: String,
        template: TemplateSelection,
        previousBudget: Budget?,
    ): Budget

    suspend fun saveBudget(budget: Budget): Budget

    suspend fun deleteBudget(budget: Budget)

    fun removeRecent(uri: Uri)
}

internal class BudgetRepository(
    context: Context,
    private val ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) : BudgetDataSource {
    private val applicationContext = context.applicationContext
    private val resolver = applicationContext.contentResolver
    private val preferences = applicationContext.getSharedPreferences(
        BudgetWardenApplication.PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )

    override suspend fun loadStoredBudgets(): List<StoredBudget> = withContext(ioDispatcher) {
        val valid = recentUriStrings().mapNotNull { value ->
            val uri = Uri.parse(value)
            runCatching {
                StoredBudget(
                    budget = readBudget(uri),
                    uri = uri,
                    displayName = displayName(uri),
                )
            }.getOrNull()
        }
        saveRecentUris(valid.map { it.uri.toString() })
        valid
    }

    override suspend fun openBudget(uri: Uri): Budget = withContext(ioDispatcher) {
        retainAccess(uri)
        readBudget(uri).also { rememberRecent(uri) }
    }

    override suspend fun createBudget(
        uri: Uri,
        title: String,
        template: TemplateSelection,
        previousBudget: Budget?,
    ): Budget = withContext(ioDispatcher) {
        val trimmedTitle = title.trim()
        require(trimmedTitle.isNotEmpty()) { "Budget title cannot be empty." }
        retainAccess(uri)

        val created = when (template) {
            TemplateSelection.BASIC -> budgetFromTemplate(BWTemplateType.BASIC_MONTHLY, trimmedTitle)
            TemplateSelection.BLANK -> budgetFromTemplate(BWTemplateType.EMPTY, trimmedTitle)
            TemplateSelection.PREVIOUS -> previousBudget
                ?.let { budgetFromPreviousBudget(it, trimmedTitle) }
                ?: budgetFromTemplate(BWTemplateType.BASIC_MONTHLY, trimmedTitle)
        }.copy(url = uri.toString())

        writeBudget(created)
        rememberRecent(uri)
        created
    }

    override suspend fun saveBudget(budget: Budget): Budget = withContext(ioDispatcher) {
        val normalizedInMemory = budget.updateActuals()
        val uri = Uri.parse(normalizedInMemory.url ?: error("Budget has no document URI."))
        val onDisk = readBudget(uri)
        val merged = mergeBudgetForSave(normalizedInMemory, onDisk).updateActuals()
        writeBudget(merged)
        rememberRecent(uri)
        merged
    }

    override suspend fun deleteBudget(budget: Budget) = withContext(ioDispatcher) {
        val uri = Uri.parse(budget.url ?: error("Budget has no document URI."))
        val deleted = if (DocumentsContract.isDocumentUri(applicationContext, uri)) {
            DocumentsContract.deleteDocument(resolver, uri)
        } else {
            resolver.delete(uri, null, null) != 0
        }
        check(deleted) { "The document provider could not delete this budget." }
        removeRecent(uri)
    }

    override fun removeRecent(uri: Uri) {
        saveRecentUris(recentUriStrings().filterNot { it == uri.toString() })
    }

    fun normalizedFileName(title: String): String {
        val cleaned = title
            .trim()
            .replace(Regex("""[/\\?%*|"<>:\p{Cntrl}]"""), "-")
            .replace(Regex("""\s+"""), " ")
            .trim()
        return (cleaned.ifEmpty { "Untitled Budget" }) + ".budget"
    }

    private fun readBudget(uri: Uri): BWBudget {
        val json = resolver.openInputStream(uri)
            ?.bufferedReader()
            ?.use { it.readText() }
            ?: error("Could not read the selected budget file.")
        var budget = decodeBudget(json = json, url = uri.toString())

        // TEMPORARY LEGACY MIGRATION: remove this writeback together with the
        // Rust schema-v1 fallback after live files have been upgraded.
        if (budget.requiresMigrationWriteback) {
            writeBudget(budget)
            budget = budget.copy(requiresMigrationWriteback = false)
        }
        return budget
    }

    private fun writeBudget(budget: Budget) {
        val uri = Uri.parse(budget.url ?: error("Budget has no document URI."))
        val json = encodeBudget(budget)
        resolver.openOutputStream(uri, "rwt")
            ?.bufferedWriter()
            ?.use { it.write(json) }
            ?: error("Could not write the budget file.")
    }

    private fun displayName(uri: Uri): String =
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        } ?: uri.lastPathSegment ?: "Budget"

    private fun retainAccess(uri: Uri) {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        runCatching { resolver.takePersistableUriPermission(uri, flags) }
            .recoverCatching {
                resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
    }

    private fun rememberRecent(uri: Uri) {
        val value = uri.toString()
        val updated = listOf(value) + recentUriStrings().filterNot { it == value }
        saveRecentUris(updated.take(MAX_RECENT_FILES))
    }

    private fun recentUriStrings(): List<String> =
        preferences.getString(RECENT_FILES_KEY, null)
            ?.lineSequence()
            ?.filter(String::isNotBlank)
            ?.toList()
            .orEmpty()

    private fun saveRecentUris(values: List<String>) {
        preferences.edit().putString(RECENT_FILES_KEY, values.joinToString("\n")).apply()
    }

    companion object {
        private const val RECENT_FILES_KEY = "recent_budget_uris_v1"
        private const val MAX_RECENT_FILES = 20
    }
}
