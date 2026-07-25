package com.lazarovco.budgetwarden.domain

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.Date
import java.util.UUID

data class CrdtStamp(
    val replicaID: String,
    val sequence: Long,
    val context: Map<String, Long>,
    val physicalMilliseconds: Long,
    val logical: Long,
) {
    fun observes(other: CrdtStamp): Boolean =
        (replicaID == other.replicaID && sequence == other.sequence) ||
            (context[other.replicaID] ?: 0L) >= other.sequence

    fun compareTotal(other: CrdtStamp): Int =
        compareValuesBy(this, other, CrdtStamp::physicalMilliseconds, CrdtStamp::logical, CrdtStamp::replicaID, CrdtStamp::sequence)
}

data class CrdtRegister<T>(val value: T, val stamp: CrdtStamp)
data class CrdtLegacyBaseline(val revision: Long, val fingerprint: String) : Comparable<CrdtLegacyBaseline> {
    override fun compareTo(other: CrdtLegacyBaseline): Int =
        compareValuesBy(this, other, CrdtLegacyBaseline::revision, CrdtLegacyBaseline::fingerprint)
}

data class CrdtCategoryState(
    val presence: CrdtRegister<Boolean>,
    val ordinal: CrdtRegister<Int>,
    val title: CrdtRegister<String>,
    val amountPlanned: CrdtRegister<Long>,
    val amountAccumulated: CrdtRegister<Long>,
    val categoryType: CrdtRegister<CategoryType>,
)

data class CrdtTransactionState(
    val presence: CrdtRegister<Boolean>,
    val parentCategoryID: CrdtRegister<String>,
    val title: CrdtRegister<String>,
    val description: CrdtRegister<String>,
    val date: CrdtRegister<Date>,
    val amount: CrdtRegister<Long>,
)

data class BudgetCrdtState(
    val versionVector: Map<String, Long>,
    val maximumStamp: CrdtStamp,
    val legacyBaseline: CrdtLegacyBaseline?,
    val title: CrdtRegister<String>,
    val categories: Map<String, CrdtCategoryState>,
    val transactions: Map<String, CrdtTransactionState>,
) {
    val containsOnlyLegacyEvents: Boolean
        get() = versionVector.isNotEmpty() && versionVector.keys.all { it.startsWith("legacy:") }
}

class BudgetCrdtClock(context: Context) {
    private val preferences = context.applicationContext.getSharedPreferences("budget-crdt-v2", Context.MODE_PRIVATE)

    fun next(state: BudgetCrdtState): CrdtStamp = synchronized(lock) {
        val replicaID = preferences.getString("replica-id", null) ?: UUID.randomUUID().toString().lowercase().also {
            preferences.edit().putString("replica-id", it).apply()
        }
        val sequence = maxOf(preferences.getLong("sequence", 0L), state.versionVector[replicaID] ?: 0L) + 1L
        val wall = System.currentTimeMillis()
        val previousPhysical = preferences.getLong("physical", 0L)
        val physical = maxOf(wall, previousPhysical, state.maximumStamp.physicalMilliseconds)
        val logical = if (physical == previousPhysical || physical == state.maximumStamp.physicalMilliseconds) {
            maxOf(preferences.getLong("logical", 0L), state.maximumStamp.logical) + 1L
        } else 0L
        preferences.edit()
            .putLong("sequence", sequence)
            .putLong("physical", physical)
            .putLong("logical", logical)
            .commit()
        CrdtStamp(replicaID, sequence, state.versionVector, physical, logical)
    }

    private companion object {
        val lock = Any()
    }
}

object BudgetCrdt {
    const val SCHEMA_VERSION = 2

    fun migrateLegacy(budget: Budget): Budget {
        val fingerprint = legacyFingerprint(budget)
        val replicaID = "legacy:${budget.revision}:$fingerprint"
        val stamp = CrdtStamp(replicaID, 1L, emptyMap(), 0L, budget.revision)
        return materialize(budget.copy(
            schemaVersion = SCHEMA_VERSION,
            crdt = makeState(budget, stamp, CrdtLegacyBaseline(budget.revision, fingerprint)),
        ))
    }

    fun prepareNew(budget: Budget, clock: BudgetCrdtClock): Budget {
        val seed = migrateLegacy(budget)
        val stamp = clock.next(requireNotNull(seed.crdt))
        return materialize(budget.copy(
            schemaVersion = SCHEMA_VERSION,
            revision = 1L,
            crdt = makeState(budget, stamp, null),
        ))
    }

    fun applyChanges(originalBudget: Budget, desired: Budget, clock: BudgetCrdtClock): Budget {
        val original = ensureState(originalBudget)
        var state = requireNotNull(original.crdt)
        val stamp = clock.next(state)
        var title = state.title
        val categories = state.categories.toMutableMap()
        val transactions = state.transactions.toMutableMap()
        if (original.title != desired.title) title = CrdtRegister(desired.title, stamp)

        val oldCategories = original.categories.associateBy { it.id.lowercase() }
        val newCategories = desired.categories.associateBy { it.id.lowercase() }
        newCategories.forEach { (id, category) ->
            val old = oldCategories[id]
            val current = categories[id]
            if (old == null || current == null) {
                categories[id] = categoryState(category, stamp)
            } else {
                var touched = false
                var updated = current
                if (old.ordinal != category.ordinal) { updated = updated.copy(ordinal = CrdtRegister(category.ordinal, stamp)); touched = true }
                if (old.title != category.title) { updated = updated.copy(title = CrdtRegister(category.title, stamp)); touched = true }
                if (old.amountPlanned != category.amountPlanned) { updated = updated.copy(amountPlanned = CrdtRegister(category.amountPlanned, stamp)); touched = true }
                if (old.amountAccumulated != category.amountAccumulated) { updated = updated.copy(amountAccumulated = CrdtRegister(category.amountAccumulated, stamp)); touched = true }
                if (old.categoryType != category.categoryType) { updated = updated.copy(categoryType = CrdtRegister(category.categoryType, stamp)); touched = true }
                if (touched) updated = updated.copy(presence = CrdtRegister(true, stamp))
                categories[id] = updated
            }
        }
        oldCategories.filterKeys { it !in newCategories }.forEach { (id, category) ->
            categories[id]?.let { categories[id] = it.copy(presence = CrdtRegister(false, stamp)) }
            category.transactions.forEach { transaction ->
                transactions[transaction.id]?.let { transactions[transaction.id] = it.copy(presence = CrdtRegister(false, stamp)) }
            }
        }

        val oldTransactions = flatten(original)
        val newTransactions = flatten(desired)
        newTransactions.forEach { (id, item) ->
            val old = oldTransactions[id]
            val current = transactions[id]
            if (old == null || current == null) {
                transactions[id] = transactionState(item.second, item.first, stamp)
            } else {
                var touched = false
                var updated = current
                if (old.first != item.first) { updated = updated.copy(parentCategoryID = CrdtRegister(item.first, stamp)); touched = true }
                if (old.second.title != item.second.title) { updated = updated.copy(title = CrdtRegister(item.second.title, stamp)); touched = true }
                if (old.second.description != item.second.description) { updated = updated.copy(description = CrdtRegister(item.second.description, stamp)); touched = true }
                if (old.second.date != item.second.date) { updated = updated.copy(date = CrdtRegister(item.second.date, stamp)); touched = true }
                if (old.second.amount != item.second.amount) { updated = updated.copy(amount = CrdtRegister(item.second.amount, stamp)); touched = true }
                if (touched) {
                    updated = updated.copy(presence = CrdtRegister(true, stamp))
                    categories[item.first]?.let { categories[item.first] = it.copy(presence = CrdtRegister(true, stamp)) }
                }
                transactions[id] = updated
            }
        }
        oldTransactions.keys.filter { it !in newTransactions }.forEach { id ->
            transactions[id]?.let { transactions[id] = it.copy(presence = CrdtRegister(false, stamp)) }
        }

        state = state.copy(
            versionVector = state.versionVector + (stamp.replicaID to stamp.sequence),
            maximumStamp = maxStamp(state.maximumStamp, stamp),
            title = title,
            categories = categories,
            transactions = transactions,
        )
        return materialize(desired.copy(
            schemaVersion = SCHEMA_VERSION,
            revision = maxOf(desired.revision, state.versionVector.values.maxOrNull() ?: 1L),
            crdt = state,
        ))
    }

    fun merge(leftBudget: Budget, rightBudget: Budget): Budget {
        require(leftBudget.id == rightBudget.id) { "Cannot merge budgets with different IDs." }
        val leftDocument = ensureState(leftBudget)
        val rightDocument = ensureState(rightBudget)
        val left = requireNotNull(leftDocument.crdt)
        val right = requireNotNull(rightDocument.crdt)
        if (left.containsOnlyLegacyEvents && right.containsOnlyLegacyEvents &&
            left.legacyBaseline != null && right.legacyBaseline != null && left.legacyBaseline != right.legacyBaseline
        ) return if (left.legacyBaseline >= right.legacyBaseline) leftDocument else rightDocument

        val vector = left.versionVector.toMutableMap()
        right.versionVector.forEach { (id, value) -> vector[id] = maxOf(vector[id] ?: 0L, value) }
        val categories = left.categories.toMutableMap()
        right.categories.forEach { (id, incoming) ->
            val current = categories[id]
            categories[id] = if (current == null) incoming else CrdtCategoryState(
                mergePresence(current.presence, incoming.presence),
                mergeRegister(current.ordinal, incoming.ordinal),
                mergeRegister(current.title, incoming.title),
                mergeRegister(current.amountPlanned, incoming.amountPlanned),
                mergeRegister(current.amountAccumulated, incoming.amountAccumulated),
                mergeRegister(current.categoryType, incoming.categoryType),
            )
        }
        val transactions = left.transactions.toMutableMap()
        right.transactions.forEach { (id, incoming) ->
            val current = transactions[id]
            transactions[id] = if (current == null) incoming else CrdtTransactionState(
                mergePresence(current.presence, incoming.presence),
                mergeRegister(current.parentCategoryID, incoming.parentCategoryID),
                mergeRegister(current.title, incoming.title),
                mergeRegister(current.description, incoming.description),
                mergeRegister(current.date, incoming.date),
                mergeRegister(current.amount, incoming.amount),
            )
        }
        val state = left.copy(
            versionVector = vector,
            maximumStamp = maxStamp(left.maximumStamp, right.maximumStamp),
            legacyBaseline = listOfNotNull(left.legacyBaseline, right.legacyBaseline).maxOrNull(),
            title = mergeRegister(left.title, right.title),
            categories = categories,
            transactions = transactions,
        )
        return materialize(leftDocument.copy(
            schemaVersion = SCHEMA_VERSION,
            revision = maxOf(leftBudget.revision, rightBudget.revision, vector.values.maxOrNull() ?: 1L),
            crdt = state,
            fileName = leftBudget.fileName ?: rightBudget.fileName,
        ))
    }

    fun materialize(budget: Budget): Budget {
        val state = budget.crdt ?: return budget
        val categoryStates = state.categories.mapNotNull { (id, value) -> if (value.presence.value) id to value else null }
            .sortedWith(compareBy<Pair<String, CrdtCategoryState>> { it.second.categoryType.value.rawValue }
                .thenBy { it.second.ordinal.value }
                .thenComparator { a, b -> a.second.ordinal.stamp.compareTotal(b.second.ordinal.stamp) }
                .thenBy { it.first })
        val ordinals = mutableMapOf<CategoryType, Int>()
        val categories = categoryStates.map { (id, category) ->
            val ordinal = ordinals.getOrDefault(category.categoryType.value, 0)
            ordinals[category.categoryType.value] = ordinal + 1
            val transactions = state.transactions.mapNotNull { (transactionID, transaction) ->
                if (!transaction.presence.value || transaction.parentCategoryID.value != id) null
                else Transaction(
                    id = transactionID,
                    title = transaction.title.value,
                    description = transaction.description.value,
                    date = transaction.date.value,
                    amount = transaction.amount.value,
                ) to transaction.presence.stamp
            }.sortedWith { a, b ->
                a.second.compareTotal(b.second).takeIf { it != 0 } ?: a.first.id.compareTo(b.first.id)
            }.map { it.first }
            Category(
                id = id,
                ordinal = ordinal,
                title = category.title.value,
                amountPlanned = category.amountPlanned.value,
                amountActual = transactions.sumOf { it.amount },
                amountAccumulated = category.amountAccumulated.value,
                categoryType = category.categoryType.value,
                transactions = transactions,
            )
        }
        return budget.copy(title = state.title.value, categories = categories)
    }

    private fun ensureState(budget: Budget): Budget = if (budget.crdt == null) migrateLegacy(budget) else materialize(budget)
    private fun flatten(budget: Budget): Map<String, Pair<String, Transaction>> = buildMap {
        budget.categories.forEach { category -> category.transactions.forEach { put(it.id.lowercase(), category.id.lowercase() to it) } }
    }
    private fun categoryState(category: Category, stamp: CrdtStamp) = CrdtCategoryState(
        CrdtRegister(true, stamp), CrdtRegister(category.ordinal, stamp), CrdtRegister(category.title, stamp),
        CrdtRegister(category.amountPlanned, stamp), CrdtRegister(category.amountAccumulated, stamp), CrdtRegister(category.categoryType, stamp),
    )
    private fun transactionState(transaction: Transaction, parentID: String, stamp: CrdtStamp) = CrdtTransactionState(
        CrdtRegister(true, stamp), CrdtRegister(parentID, stamp), CrdtRegister(transaction.title, stamp),
        CrdtRegister(transaction.description, stamp), CrdtRegister(transaction.date, stamp), CrdtRegister(transaction.amount, stamp),
    )
    private fun makeState(budget: Budget, stamp: CrdtStamp, baseline: CrdtLegacyBaseline?): BudgetCrdtState = BudgetCrdtState(
        mapOf(stamp.replicaID to stamp.sequence), stamp, baseline, CrdtRegister(budget.title, stamp),
        budget.categories.associate { it.id.lowercase() to categoryState(it, stamp) },
        budget.categories.flatMap { category -> category.transactions.map { it.id.lowercase() to transactionState(it, category.id.lowercase(), stamp) } }.toMap(),
    )
    private fun <T> mergeRegister(left: CrdtRegister<T>, right: CrdtRegister<T>): CrdtRegister<T> = when {
        left.stamp == right.stamp -> left
        left.stamp.observes(right.stamp) -> left
        right.stamp.observes(left.stamp) -> right
        left.stamp.compareTotal(right.stamp) >= 0 -> left
        else -> right
    }
    private fun mergePresence(left: CrdtRegister<Boolean>, right: CrdtRegister<Boolean>): CrdtRegister<Boolean> = when {
        left.stamp == right.stamp -> left
        left.stamp.observes(right.stamp) -> left
        right.stamp.observes(left.stamp) -> right
        left.value != right.value -> if (left.value) right else left
        left.stamp.compareTotal(right.stamp) >= 0 -> left
        else -> right
    }
    private fun maxStamp(left: CrdtStamp, right: CrdtStamp) = if (left.compareTotal(right) >= 0) left else right
    private fun legacyFingerprint(budget: Budget): String {
        val text = buildString {
            append("${budget.id.lowercase()}|${budget.revision}|${budget.title}")
            budget.categories.sortedBy { it.id }.forEach { category ->
                append("|c:${category.id.lowercase()}:${category.ordinal}:${category.title}:${category.amountPlanned}:${category.amountAccumulated}:${category.categoryType.rawValue}")
                category.transactions.sortedBy { it.id }.forEach { transaction ->
                    append("|t:${transaction.id.lowercase()}:${transaction.title}:${transaction.description}:${transaction.date.time}:${transaction.amount}")
                }
            }
        }
        var hash = 14_695_981_039_346_656_037uL
        text.encodeToByteArray().forEach { byte -> hash = (hash xor byte.toUByte().toULong()) * 1_099_511_628_211uL }
        return hash.toString(16)
    }
}

object BudgetCrdtJson {
    fun encode(state: BudgetCrdtState): JSONObject = JSONObject()
        .put("versionVector", JSONObject(state.versionVector))
        .put("maximumStamp", stamp(state.maximumStamp))
        .put("legacyBaseline", state.legacyBaseline?.let { JSONObject().put("revision", it.revision).put("fingerprint", it.fingerprint) })
        .put("title", register(state.title) { it })
        .put("categories", JSONObject().apply { state.categories.toSortedMap().forEach { (id, value) -> put(id, category(value)) } })
        .put("transactions", JSONObject().apply { state.transactions.toSortedMap().forEach { (id, value) -> put(id, transaction(value)) } })

    fun decode(json: JSONObject): BudgetCrdtState = BudgetCrdtState(
        json.getJSONObject("versionVector").keys().asSequence().associateWith { json.getJSONObject("versionVector").getLong(it) },
        stamp(json.getJSONObject("maximumStamp")),
        json.optJSONObject("legacyBaseline")?.let { CrdtLegacyBaseline(it.getLong("revision"), it.getString("fingerprint")) },
        register(json.getJSONObject("title")) { it.getString("value") },
        json.getJSONObject("categories").keys().asSequence().associate { it.lowercase() to category(json.getJSONObject("categories").getJSONObject(it)) },
        json.getJSONObject("transactions").keys().asSequence().associate { it.lowercase() to transaction(json.getJSONObject("transactions").getJSONObject(it)) },
    )

    private fun stamp(value: CrdtStamp) = JSONObject().put("replicaID", value.replicaID).put("sequence", value.sequence)
        .put("context", JSONObject(value.context)).put("physicalMilliseconds", value.physicalMilliseconds).put("logical", value.logical)
    private fun stamp(value: JSONObject): CrdtStamp = CrdtStamp(
        value.getString("replicaID"), value.getLong("sequence"),
        value.getJSONObject("context").keys().asSequence().associateWith { value.getJSONObject("context").getLong(it) },
        value.getLong("physicalMilliseconds"), value.getLong("logical"),
    )
    private fun <T> register(value: CrdtRegister<T>, encode: (T) -> Any) = JSONObject().put("value", encode(value.value)).put("stamp", stamp(value.stamp))
    private fun <T> register(value: JSONObject, decode: (JSONObject) -> T) = CrdtRegister(decode(value), stamp(value.getJSONObject("stamp")))
    private fun category(value: CrdtCategoryState) = JSONObject()
        .put("presence", register(value.presence) { it }).put("ordinal", register(value.ordinal) { it })
        .put("title", register(value.title) { it }).put("amountPlanned", register(value.amountPlanned) { it })
        .put("amountAccumulated", register(value.amountAccumulated) { it }).put("categoryType", register(value.categoryType) { it.rawValue })
    private fun category(value: JSONObject) = CrdtCategoryState(
        register(value.getJSONObject("presence")) { it.getBoolean("value") }, register(value.getJSONObject("ordinal")) { it.getInt("value") },
        register(value.getJSONObject("title")) { it.getString("value") }, register(value.getJSONObject("amountPlanned")) { it.getLong("value") },
        register(value.getJSONObject("amountAccumulated")) { it.getLong("value") },
        register(value.getJSONObject("categoryType")) { CategoryType.fromRawValue(it.getInt("value")) },
    )
    private fun transaction(value: CrdtTransactionState) = JSONObject()
        .put("presence", register(value.presence) { it }).put("parentCategoryID", register(value.parentCategoryID) { it.lowercase() })
        .put("title", register(value.title) { it }).put("description", register(value.description) { it })
        .put("date", register(value.date) { BudgetDates.encode(it) }).put("amount", register(value.amount) { it })
    private fun transaction(value: JSONObject) = CrdtTransactionState(
        register(value.getJSONObject("presence")) { it.getBoolean("value") }, register(value.getJSONObject("parentCategoryID")) { it.getString("value").lowercase() },
        register(value.getJSONObject("title")) { it.getString("value") }, register(value.getJSONObject("description")) { it.getString("value") },
        register(value.getJSONObject("date")) { BudgetDates.decode(it.getString("value")) }, register(value.getJSONObject("amount")) { it.getLong("value") },
    )
}
