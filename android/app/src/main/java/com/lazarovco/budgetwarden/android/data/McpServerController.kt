package com.lazarovco.budgetwarden.android.data

import android.content.Context
import android.net.Uri
import com.lazarovco.budgetwarden.android.BudgetWardenApplication
import com.lazarovco.budgetwarden.core.BWMcpBudgetLocation
import com.lazarovco.budgetwarden.core.BWMcpHost
import com.lazarovco.budgetwarden.core.BWMcpServer
import com.lazarovco.budgetwarden.core.BWMcpServerConfig
import com.lazarovco.budgetwarden.core.FfiException
import com.lazarovco.budgetwarden.core.generateMcpToken
import java.io.File
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow

internal data class McpServerUiState(
    val enabled: Boolean = false,
    val allowNetwork: Boolean = false,
    val url: String? = null,
    val error: String? = null,
)

/** Work the MCP server asks the app UI to do. */
internal sealed interface McpEvent {
    data class BudgetChanged(val uri: Uri) : McpEvent

    data class BudgetCreated(val uri: Uri) : McpEvent

    data class ShowBudget(val uri: Uri) : McpEvent
}

/**
 * Runs the core MCP server for the app process and gives it access to the
 * open and recent budget documents.
 */
internal class McpServerController(context: Context) {
    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(
        BudgetWardenApplication.PREFERENCES_NAME,
        Context.MODE_PRIVATE,
    )
    private val server = BWMcpServer()
    private val host = Host(BudgetRepository(applicationContext))
    private val _state = MutableStateFlow(McpServerUiState())
    private val _events = MutableSharedFlow<McpEvent>(
        extraBufferCapacity = 64,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    val state: StateFlow<McpServerUiState> = _state.asStateFlow()
    val events: SharedFlow<McpEvent> = _events.asSharedFlow()

    init {
        if (preferences.getString(TOKEN_KEY, null).orEmpty().length < 16) {
            preferences.edit().putString(TOKEN_KEY, generateMcpToken()).apply()
        }
        apply()
    }

    /** Shares the open budget and display currency with the server. */
    fun updateBudgets(openBudget: Uri?, currencyCode: String) {
        host.update(openBudget, currencyCode)
    }

    fun setEnabled(enabled: Boolean) {
        preferences.edit().putBoolean(ENABLED_KEY, enabled).apply()
        apply()
    }

    fun setAllowNetwork(allowNetwork: Boolean) {
        preferences.edit().putBoolean(ALLOW_NETWORK_KEY, allowNetwork).apply()
        apply()
    }

    /** Replaces the secret in the server URL, disconnecting existing clients. */
    fun regenerateUrl() {
        preferences.edit().putString(TOKEN_KEY, generateMcpToken()).apply()
        apply()
    }

    @Synchronized
    private fun apply() {
        val enabled = preferences.getBoolean(ENABLED_KEY, false)
        val allowNetwork = preferences.getBoolean(ALLOW_NETWORK_KEY, false)
        if (!enabled) {
            server.stop()
            _state.value = McpServerUiState(enabled = false, allowNetwork = allowNetwork)
            return
        }

        _state.value = try {
            val status = server.start(
                host,
                BWMcpServerConfig(
                    port = preferences.getInt(PORT_KEY, 0),
                    token = preferences.getString(TOKEN_KEY, null).orEmpty(),
                    allowNetwork = allowNetwork,
                ),
            )
            McpServerUiState(enabled = true, allowNetwork = allowNetwork, url = status.url)
        } catch (error: FfiException) {
            McpServerUiState(enabled = true, allowNetwork = allowNetwork, error = error.message)
        }
    }

    private inner class Host(private val repository: BudgetRepository) : BWMcpHost {
        @Volatile private var openBudget: Uri? = null
        @Volatile private var currency: String = "USD"

        fun update(openBudget: Uri?, currencyCode: String) {
            this.openBudget = openBudget
            currency = currencyCode
        }

        override fun listBudgets(): List<BWMcpBudgetLocation> {
            val open = openBudget
            return (listOfNotNull(open) + repository.recentBudgetUris())
                .distinct()
                .map { BWMcpBudgetLocation(location = it.toString(), isOpen = it == open) }
        }

        override fun readBudgetFile(location: String): String =
            repository.readBudgetJson(knownUri(location))

        override fun writeBudgetFile(location: String, json: String) {
            repository.writeBudgetJson(knownUri(location), json)
        }

        override fun createBudgetFile(fileName: String, json: String): String {
            val directory = applicationContext.getExternalFilesDir(BUDGETS_DIRECTORY)
                ?: File(applicationContext.filesDir, BUDGETS_DIRECTORY)
            check(directory.isDirectory || directory.mkdirs()) {
                "Could not create a folder for new budgets."
            }
            val stem = fileName.removeSuffix(".budget")
            val file = generateSequence(1) { it + 1 }
                .map { index -> File(directory, if (index == 1) fileName else "$stem $index.budget") }
                .first { !it.exists() }
            check(file.createNewFile()) { "Could not create ${file.name}." }
            val uri = Uri.fromFile(file)
            repository.writeBudgetJson(uri, json)
            repository.rememberCreatedBudget(uri)
            _events.tryEmit(McpEvent.BudgetCreated(uri))
            return uri.toString()
        }

        override fun budgetDidChange(location: String) {
            _events.tryEmit(McpEvent.BudgetChanged(Uri.parse(location)))
        }

        override fun showBudget(location: String) {
            _events.tryEmit(McpEvent.ShowBudget(knownUri(location)))
        }

        override fun currencyCode(): String = currency

        private fun knownUri(location: String): Uri =
            listBudgets().firstOrNull { it.location == location }
                ?.let { Uri.parse(it.location) }
                ?: throw IllegalArgumentException("$location is not one of Budget Warden's budgets.")
    }

    private companion object {
        const val ENABLED_KEY = "mcp_enabled"
        const val ALLOW_NETWORK_KEY = "mcp_allow_network"
        const val PORT_KEY = "mcp_port"
        const val TOKEN_KEY = "mcp_token"
        const val BUDGETS_DIRECTORY = "Budgets"
    }
}
