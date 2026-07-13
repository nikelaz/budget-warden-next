package com.lazarovco.budgetwarden.data

import android.content.Context
import android.net.Uri
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.BudgetDates
import com.lazarovco.budgetwarden.domain.BudgetTemplates
import com.lazarovco.budgetwarden.domain.BudgetRebaseOperation
import com.lazarovco.budgetwarden.domain.BudgetCrdt
import com.lazarovco.budgetwarden.domain.BudgetCrdtClock
import com.lazarovco.budgetwarden.domain.BudgetCrdtJson
import com.lazarovco.budgetwarden.domain.Category
import com.lazarovco.budgetwarden.domain.CategoryType
import com.lazarovco.budgetwarden.domain.TemplateSelection
import com.lazarovco.budgetwarden.domain.Transaction
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID
import com.lazarovco.budgetwarden.BudgetWardenApplication
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class BudgetRepository(private val context: Context) {
    private val application = context.applicationContext as BudgetWardenApplication
    private val writeScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val localVaultDirectory = File(context.filesDir, "Budget Warden Vaults").apply { mkdirs() }
    private val driveCacheDirectory = File(context.filesDir, "Google Drive Vault Cache").apply { mkdirs() }
    private val crdtClock = BudgetCrdtClock(context)
    data class StoredBudget(val budget: Budget, val storage: VaultType)

    private fun directoryFor(storage: VaultType): File = when (storage) {
        VaultType.GOOGLE_DRIVE -> driveCacheDirectory
        VaultType.LOCAL -> localVaultDirectory
    }

    val vaultPath: String
        get() = localVaultDirectory.absolutePath

    fun loadBudgets(storage: VaultType): List<Budget> =
        directoryFor(storage)
            .listFiles { file -> file.isFile && file.extension.equals("budget", ignoreCase = true) }
            .orEmpty()
            .mapNotNull { file ->
                runCatching {
                    BudgetFileLocks.withLock(file) {
                        val json = file.readText()
                        val wasLegacy = JSONObject(json).optInt("schemaVersion", 1) < BudgetCrdt.SCHEMA_VERSION
                        val budget = decodeBudget(json, file.name)
                        if (wasLegacy) atomicWrite(file, encodeBudget(budget))
                        budget
                    }
                }.getOrNull()
            }
            .sortedBy { it.title.lowercase() }

    fun loadStoredBudgets(): List<StoredBudget> =
        VaultType.entries.flatMap { storage -> loadBudgets(storage).map { StoredBudget(it, storage) } }

    fun createBudget(title: String, template: TemplateSelection, previousBudget: Budget?, storage: VaultType): Budget {
        val trimmedTitle = title.trim()
        require(trimmedTitle.isNotEmpty())

        val budget = when (template) {
            TemplateSelection.BASIC -> BudgetTemplates.basicBudget(trimmedTitle)
            TemplateSelection.BLANK -> Budget(title = trimmedTitle)
            TemplateSelection.PREVIOUS -> previousBudget?.cloneAsTemplate(trimmedTitle) ?: BudgetTemplates.basicBudget(trimmedTitle)
        }

        return saveNewBudget(BudgetCrdt.prepareNew(budget, crdtClock), storage)
    }

    fun saveBudget(budget: Budget, storage: VaultType, _operation: BudgetRebaseOperation): Budget {
        val fileName = budget.fileName ?: uniqueFileName(budget.title, storage)
        val file = File(directoryFor(storage), fileName)
        return BudgetFileLocks.withLock(file) {
            val original = BudgetCrdt.materialize(budget)
            val normalizedInMemory = normalizeActualAmounts(budget)
            check(file.exists()) { "Merge failed: budget file does not exist." }
            val changed = BudgetCrdt.applyChanges(original, normalizedInMemory, crdtClock)
            val onDisk = decodeBudget(file.readText(), fileName)
            val normalized = normalizeActualAmounts(BudgetCrdt.merge(changed, onDisk))
            atomicWrite(file, encodeBudget(normalized))
            val saved = normalized.copy(fileName = fileName)
            cacheForUpload(saved, file, storage)
            saved
        }
    }

    fun deleteBudget(budget: Budget, storage: VaultType) {
        budget.fileName?.let { File(directoryFor(storage), it).delete() }
        if (storage == VaultType.GOOGLE_DRIVE) {
            writeScope.launch {
                val dao = application.vaultDatabase.vaultFiles()
                val cached = dao.byBudgetId(budget.id) ?: return@launch
                if (cached.driveFileId == null) dao.delete(budget.id)
                else dao.upsert(listOf(cached.copy(syncState = "PENDING_DELETE")))
                VaultSyncWorker.enqueue(context)
            }
        }
    }

    fun importBudget(uri: Uri): Budget {
        val json = context.contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() }
            ?: error("Could not read the selected file.")
        val decoded = normalizeActualAmounts(decodeBudget(json, null))
        return saveNewBudget(decoded, application.vaultPreferences.vaultType)
    }

    fun exportBudget(budget: Budget, uri: Uri) {
        context.contentResolver.openOutputStream(uri)?.bufferedWriter()?.use {
            it.write(encodeBudget(normalizeActualAmounts(budget)))
        } ?: error("Could not write to the selected file.")
    }

    fun normalizedFileName(title: String): String {
        val cleaned = title
            .trim()
            .replace(Regex("""[/\\?%*|"<>:\p{Cntrl}]"""), "-")
            .replace(Regex("""\s+"""), " ")
            .trim()
        return (cleaned.ifEmpty { "Untitled Budget" }) + ".budget"
    }

    private fun saveNewBudget(budget: Budget, storage: VaultType): Budget {
        val normalized = normalizeActualAmounts(budget)
        val fileName = uniqueFileName(normalized.title, storage)
        atomicWrite(File(directoryFor(storage), fileName), encodeBudget(normalized))
        val saved = normalized.copy(fileName = fileName)
        cacheForUpload(saved, File(directoryFor(storage), fileName), storage)
        return saved
    }

    private fun cacheForUpload(budget: Budget, file: File, storage: VaultType) {
        if (storage != VaultType.GOOGLE_DRIVE) return
        writeScope.launch {
            val dao = application.vaultDatabase.vaultFiles()
            val existing = dao.byBudgetId(budget.id)
            dao.upsert(listOf(VaultFileEntity(
                budget.id, existing?.driveFileId, file.name, file.absolutePath, existing?.ownerEmail, false,
                file.lastModified(), existing?.driveVersion, "PENDING_UPLOAD", null,
            )))
            VaultSyncWorker.enqueue(context)
        }
    }

    private fun uniqueFileName(title: String, storage: VaultType): String {
        val base = normalizedFileName(title).removeSuffix(".budget")
        var candidate = "$base.budget"
        var index = 2
        while (File(directoryFor(storage), candidate).exists()) {
            candidate = "$base $index.budget"
            index += 1
        }
        return candidate
    }

    internal fun normalizeActualAmounts(budget: Budget): Budget =
        budget.copy(
            categories = budget.categories.map { category ->
                category.copy(amountActual = category.transactions.sumOf { it.amount })
            },
        )

    internal fun encodeBudget(budget: Budget): String {
        val root = JSONObject()
            .put("id", budget.id)
            .put("revision", budget.revision)
            .put("schemaVersion", budget.schemaVersion)
            .put("title", budget.title)
            .put("categories", JSONArray().apply {
                budget.categories.forEach { category ->
                    put(JSONObject()
                        .put("id", category.id)
                        .put("ordinal", category.ordinal)
                        .put("title", category.title)
                        .put("amountPlanned", category.amountPlanned)
                        .put("amountActual", category.amountActual)
                        .put("amountAccumulated", category.amountAccumulated)
                        .put("categoryType", category.categoryType.rawValue)
                        .put("transactions", JSONArray().apply {
                            category.transactions.forEach { transaction ->
                                put(JSONObject()
                                    .put("id", transaction.id)
                                    .put("title", transaction.title)
                                    .put("description", transaction.description)
                                    .put("date", BudgetDates.encode(transaction.date))
                                    .put("amount", transaction.amount))
                            }
                        }))
                }
            })

        budget.crdt?.let { root.put("crdt", BudgetCrdtJson.encode(it)) }

        return root.toString(2)
    }

    internal fun decodeBudget(json: String, fileName: String?): Budget {
        val root = JSONObject(json)
        val decoded = Budget(
            id = root.optString("id").ifBlank { java.util.UUID.randomUUID().toString() }.lowercase(),
            revision = root.optLong("revision", 1L),
            schemaVersion = root.optInt("schemaVersion", 1),
            title = root.optString("title", "Untitled Budget"),
            categories = root.optJSONArray("categories").toCategories(),
            fileName = fileName,
            crdt = root.optJSONObject("crdt")?.let(BudgetCrdtJson::decode),
        )
        return when {
            decoded.schemaVersion < BudgetCrdt.SCHEMA_VERSION -> BudgetCrdt.migrateLegacy(decoded)
            decoded.schemaVersion == BudgetCrdt.SCHEMA_VERSION && decoded.crdt != null -> BudgetCrdt.materialize(decoded)
            else -> error("Unsupported or invalid budget schema ${decoded.schemaVersion}.")
        }
    }

    private fun JSONArray?.toCategories(): List<Category> {
        if (this == null) return emptyList()
        return List(length()) { index ->
            val item = getJSONObject(index)
            Category(
                id = item.optString("id").ifBlank { java.util.UUID.randomUUID().toString() }.lowercase(),
                ordinal = item.optInt("ordinal", index),
                title = item.optString("title", "Untitled Category"),
                amountPlanned = item.optLong("amountPlanned", 0L),
                amountActual = item.optLong("amountActual", 0L),
                amountAccumulated = item.optLong("amountAccumulated", 0L),
                categoryType = CategoryType.fromRawValue(item.optInt("categoryType", CategoryType.EXPENSES.rawValue)),
                transactions = item.optJSONArray("transactions").toTransactions(),
            )
        }
    }

    private fun JSONArray?.toTransactions(): List<Transaction> {
        if (this == null) return emptyList()
        return List(length()) { index ->
            val item = getJSONObject(index)
            Transaction(
                id = item.optString("id").ifBlank { java.util.UUID.randomUUID().toString() }.lowercase(),
                title = item.optString("title", "Untitled Transaction"),
                description = item.optString("description", ""),
                date = BudgetDates.decode(item.optString("date")),
                amount = item.optLong("amount", 0L),
            )
        }
    }

    private fun atomicWrite(file: File, contents: String) {
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, ".${file.name}.${UUID.randomUUID()}.tmp")
        temporary.writeText(contents)
        check(temporary.renameTo(file)) { "Could not atomically replace ${file.name}." }
    }
}
