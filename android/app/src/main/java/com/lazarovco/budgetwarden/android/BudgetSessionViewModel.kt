package com.lazarovco.budgetwarden.android

import android.net.Uri
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import com.lazarovco.budgetwarden.core.decodeBudget
import com.lazarovco.budgetwarden.android.data.BudgetDataSource
import com.lazarovco.budgetwarden.android.data.StoredBudget
import com.lazarovco.budgetwarden.android.domain.Budget
import com.lazarovco.budgetwarden.android.domain.TemplateSelection
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch

internal data class BudgetSessionState(
    val storedBudgets: List<StoredBudget> = emptyList(),
    val currentBudget: Budget? = null,
)

internal enum class BudgetSessionErrorKind {
    LOAD_RECENTS,
    OPEN,
    CREATE,
    SAVE,
    DELETE,
}

internal data class BudgetSessionError(
    val cause: Exception,
    val kind: BudgetSessionErrorKind,
)

internal class BudgetSessionViewModel(
    private val repository: BudgetDataSource,
    initialState: BudgetSessionState = BudgetSessionState(),
) : ViewModel() {
    private val commands = Channel<Command>(Channel.UNLIMITED)
    private val _state = MutableStateFlow(initialState)
    private val _errors = Channel<BudgetSessionError>(Channel.BUFFERED)

    val state: StateFlow<BudgetSessionState> = _state.asStateFlow()
    val errors: Flow<BudgetSessionError> = _errors.receiveAsFlow()

    init {
        viewModelScope.launch {
            for (command in commands) {
                process(command)
            }
        }
        commands.trySend(Command.LoadRecents)
    }

    fun openBudget(uri: Uri) {
        commands.trySend(Command.Open(uri))
    }

    fun createBudget(
        uri: Uri,
        title: String,
        template: TemplateSelection,
        previousBudgetJson: String?,
    ) {
        commands.trySend(Command.Create(uri, title, template, previousBudgetJson))
    }

    fun mutateBudget(operation: (Budget) -> Budget) {
        commands.trySend(Command.Mutate(operation))
    }

    fun deleteBudget(storedBudget: StoredBudget) {
        commands.trySend(Command.Delete(storedBudget))
    }

    fun closeBudget() {
        commands.trySend(Command.Close)
    }

    private suspend fun process(command: Command) {
        try {
            when (command) {
                Command.LoadRecents -> refreshRecents()
                is Command.Open -> {
                    val opened = repository.openBudget(command.uri)
                    _state.value = _state.value.copy(currentBudget = opened)
                    refreshRecents()
                }
                is Command.Create -> {
                    val previousBudget = command.previousBudgetJson?.let { decodeBudget(it, "") }
                    val created = repository.createBudget(
                        uri = command.uri,
                        title = command.title,
                        template = command.template,
                        previousBudget = previousBudget,
                    )
                    _state.value = _state.value.copy(currentBudget = created)
                    refreshRecents()
                }
                is Command.Mutate -> {
                    val current = _state.value.currentBudget ?: return
                    val saved = repository.saveBudget(command.operation(current))
                    _state.value = _state.value.copy(currentBudget = saved)
                    refreshRecents()
                }
                is Command.Delete -> {
                    repository.deleteBudget(command.storedBudget.budget)
                    val current = _state.value.currentBudget
                    _state.value = _state.value.copy(
                        currentBudget = current?.takeUnless {
                            it.id == command.storedBudget.budget.id
                        },
                    )
                    refreshRecents()
                }
                Command.Close -> {
                    _state.value = _state.value.copy(currentBudget = null)
                }
            }
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            _errors.send(BudgetSessionError(error, command.errorKind))
        }
    }

    private suspend fun refreshRecents() {
        try {
            _state.value = _state.value.copy(storedBudgets = repository.loadStoredBudgets())
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            _errors.send(BudgetSessionError(error, BudgetSessionErrorKind.LOAD_RECENTS))
        }
    }

    override fun onCleared() {
        commands.close()
        _errors.close()
        super.onCleared()
    }

    private sealed interface Command {
        data object LoadRecents : Command

        data class Open(val uri: Uri) : Command

        data class Create(
            val uri: Uri,
            val title: String,
            val template: TemplateSelection,
            val previousBudgetJson: String?,
        ) : Command

        data class Mutate(val operation: (Budget) -> Budget) : Command

        data class Delete(val storedBudget: StoredBudget) : Command

        data object Close : Command

        val errorKind: BudgetSessionErrorKind
            get() = when (this) {
                LoadRecents -> BudgetSessionErrorKind.LOAD_RECENTS
                is Open -> BudgetSessionErrorKind.OPEN
                is Create -> BudgetSessionErrorKind.CREATE
                is Mutate -> BudgetSessionErrorKind.SAVE
                is Delete -> BudgetSessionErrorKind.DELETE
                Close -> BudgetSessionErrorKind.SAVE
            }
    }

    class Factory(
        private val repository: BudgetDataSource,
    ) : ViewModelProvider.Factory {
        @Suppress("UNCHECKED_CAST")
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            require(modelClass.isAssignableFrom(BudgetSessionViewModel::class.java))
            return BudgetSessionViewModel(repository) as T
        }
    }
}
