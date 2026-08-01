package com.lazarovco.budgetwarden

import android.net.Uri
import com.google.common.truth.Truth.assertThat
import com.lazarovco.budgetwarden.core.BWBudget
import com.lazarovco.budgetwarden.core.CRDTChanges
import com.lazarovco.budgetwarden.data.BudgetDataSource
import com.lazarovco.budgetwarden.data.StoredBudget
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.TemplateSelection
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
internal class BudgetSessionViewModelTest {
    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    @Test
    fun overlappingMutationsAreSavedSeriallyAgainstLatestState() = runTest {
        val repository = PausingBudgetDataSource()
        val viewModel = BudgetSessionViewModel(
            repository = repository,
            initialState = BudgetSessionState(currentBudget = budget("Original")),
        )
        advanceUntilIdle()

        viewModel.mutateBudget { it.copy(title = "${it.title} first") }
        runCurrent()
        repository.firstSaveStarted.await()

        viewModel.mutateBudget { it.copy(title = "${it.title} second") }
        runCurrent()

        assertThat(repository.saveCalls).isEqualTo(1)
        assertThat(repository.maximumConcurrentSaves).isEqualTo(1)

        repository.releaseFirstSave.complete(Unit)
        advanceUntilIdle()

        assertThat(repository.saveCalls).isEqualTo(2)
        assertThat(repository.maximumConcurrentSaves).isEqualTo(1)
        assertThat(viewModel.state.value.currentBudget?.title)
            .isEqualTo("Original first second")
    }

    private fun budget(title: String): BWBudget = BWBudget(
        id = UUID.randomUUID(),
        revision = 0,
        revisionId = UUID.randomUUID(),
        schemaVersion = 2,
        title = title,
        categories = emptyList(),
        changes = CRDTChanges(
            budget = emptyList(),
            categories = emptyMap(),
            transactions = emptyMap(),
            categoryTombstones = emptyMap(),
            transactionTombstones = emptyMap(),
        ),
        url = "content://tests/budget.budget",
        requiresMigrationWriteback = false,
    )

    private class PausingBudgetDataSource : BudgetDataSource {
        val firstSaveStarted = CompletableDeferred<Unit>()
        val releaseFirstSave = CompletableDeferred<Unit>()
        var saveCalls = 0
            private set
        var maximumConcurrentSaves = 0
            private set
        private var concurrentSaves = 0

        override suspend fun loadStoredBudgets(): List<StoredBudget> = emptyList()

        override suspend fun saveBudget(budget: Budget): Budget {
            saveCalls += 1
            concurrentSaves += 1
            maximumConcurrentSaves = maxOf(maximumConcurrentSaves, concurrentSaves)
            try {
                if (saveCalls == 1) {
                    firstSaveStarted.complete(Unit)
                    releaseFirstSave.await()
                }
                return budget
            } finally {
                concurrentSaves -= 1
            }
        }

        override suspend fun openBudget(uri: Uri): Budget = error("Not used")

        override suspend fun createBudget(
            uri: Uri,
            title: String,
            template: TemplateSelection,
            previousBudget: Budget?,
        ): Budget = error("Not used")

        override suspend fun deleteBudget(budget: Budget) = Unit

        override fun removeRecent(uri: Uri) = Unit
    }
}
