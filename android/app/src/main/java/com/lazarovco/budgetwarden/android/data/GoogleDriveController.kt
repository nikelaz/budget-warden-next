package com.lazarovco.budgetwarden.android.data

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import com.google.android.gms.auth.GoogleAuthUtil
import com.google.android.gms.auth.api.identity.AuthorizationClient
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Tasks
import com.lazarovco.budgetwarden.android.BuildConfig
import com.lazarovco.budgetwarden.core.BWCloudBudget
import com.lazarovco.budgetwarden.core.BWCloudShare
import com.lazarovco.budgetwarden.core.BWCloudShareRole
import com.lazarovco.budgetwarden.core.BWGoogleCredentialStore
import com.lazarovco.budgetwarden.core.BWGoogleDrive
import com.lazarovco.budgetwarden.core.BWGoogleDriveConfig
import com.lazarovco.budgetwarden.core.BWGoogleTokenSource
import com.lazarovco.budgetwarden.core.cloudErrorMessage
import com.lazarovco.budgetwarden.core.isCloudSignInRequired
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

internal data class GoogleDriveUiState(
    /** This build can use Google Drive. */
    val enabled: Boolean = false,
    val signedIn: Boolean = false,
    val signingIn: Boolean = false,
    /** This build can add budgets others shared with the user. */
    val canAddShared: Boolean = false,
    val email: String? = null,
    val budgets: List<BWCloudBudget> = emptyList(),
    val refreshing: Boolean = false,
    val error: String? = null,
)

/** A Google Drive problem with the core's sign-in marker removed. */
internal class CloudException(message: String, val requiresSignIn: Boolean) : Exception(message)

/**
 * Google Drive budgets for the app process: Google Play services sign-in,
 * listing (including budgets shared with the user), opening, sync after
 * saves, and sharing.
 *
 * A cloud budget opens from a working copy in app storage, a `file:` URI the
 * repository reads and saves like any other budget.
 */
internal class GoogleDriveController(context: Context) {
    private val applicationContext = context.applicationContext
    private val preferences = applicationContext.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
    private val authorizer = PlayServicesTokenSource(applicationContext)
    private val drive = BWGoogleDrive(
        BWGoogleDriveConfig(
            clientId = "",
            clientSecret = null,
            cacheDirectory = File(applicationContext.filesDir, "cloud").path,
            folderName = "Budget Warden",
            pickerUrl = BuildConfig.GOOGLE_PICKER_URL.ifBlank { null },
        ),
    )
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val scheduler = CoalescingSyncScheduler(scope, ::syncNow)
    private val _state = MutableStateFlow(
        GoogleDriveUiState(
            enabled = BuildConfig.GOOGLE_DRIVE_ENABLED,
            canAddShared = BuildConfig.GOOGLE_PICKER_URL.isNotBlank(),
        ),
    )
    private val _changes = MutableSharedFlow<Uri>(
        extraBufferCapacity = 16,
        onBufferOverflow = BufferOverflow.DROP_OLDEST,
    )

    val state: StateFlow<GoogleDriveUiState> = _state.asStateFlow()

    /** Working copies that sync rewrote; an open one must be reloaded. */
    val changes: SharedFlow<Uri> = _changes.asSharedFlow()

    init {
        drive.connect(HttpUrlConnectionClient(), PreferencesCredentialStore(preferences))
        drive.useTokenSource(authorizer)
        publishAccount(budgets = drive.cachedBudgets())
    }

    // Account

    /**
     * Starts authorization. Returns an intent to launch when Google needs the
     * user's consent; otherwise the sign-in completes on its own.
     */
    suspend fun beginSignIn(): PendingIntent? {
        _state.update { it.copy(signingIn = true, error = null) }
        return try {
            val result = withContext(Dispatchers.IO) { Tasks.await(authorizer.authorize()) }
            if (result.hasResolution()) {
                result.pendingIntent
            } else {
                finishSignIn(result)
                null
            }
        } catch (error: Exception) {
            _state.update { it.copy(signingIn = false, error = error.message) }
            null
        }
    }

    /** Completes authorization with the consent screen's result. */
    suspend fun completeSignIn(data: Intent?) {
        try {
            finishSignIn(authorizer.resultFromIntent(data))
        } catch (error: Exception) {
            _state.update { it.copy(signingIn = false, error = error.message) }
        }
    }

    fun cancelSignIn() {
        _state.update { it.copy(signingIn = false) }
    }

    private suspend fun finishSignIn(result: AuthorizationResult) {
        if (result.accessToken == null) {
            _state.update { it.copy(signingIn = false, error = "Google did not grant access to Drive.") }
            return
        }
        call { drive.refreshAccount() }
        publishAccount()
        _state.update { it.copy(signingIn = false) }
        refresh()
    }

    fun signOut() {
        scope.launch {
            drive.signOut()
            authorizer.forget()
            publishAccount(budgets = emptyList())
        }
    }

    private fun publishAccount(budgets: List<BWCloudBudget>? = null) {
        val account = drive.account()
        _state.update {
            it.copy(
                signedIn = drive.isSignedIn(),
                email = account?.email,
                budgets = budgets ?: it.budgets,
            )
        }
    }

    // Budgets

    /**
     * The Google Picker page where the user chooses budgets someone shared
     * with them. Budget Warden only reaches Drive files it created or that
     * the user chooses there; [refresh] lists them after the user returns.
     */
    fun sharedBudgetPickerUri(): Uri? =
        runCatching { Uri.parse(drive.sharedBudgetPickerUrl(null)) }.getOrNull()

    /** Lists the user's Google Drive budgets, including shared ones. */
    suspend fun refresh() {
        if (!_state.value.signedIn || _state.value.refreshing) return
        _state.update { it.copy(refreshing = true) }
        try {
            val budgets = call { drive.listBudgets() }
            _state.update { it.copy(budgets = budgets, refreshing = false, error = null) }
        } catch (error: CloudException) {
            _state.update { it.copy(refreshing = false, error = error.message) }
            if (error.requiresSignIn) publishAccount()
        }
    }

    /** Downloads a budget if needed and returns its working copy. */
    suspend fun open(budget: BWCloudBudget): Uri {
        val result = call { drive.openBudget(budget.id) }
        remember(result.budget)
        return Uri.fromFile(File(result.localPath))
    }

    /** Uploads an encoded budget as a new cloud budget. */
    suspend fun create(fileName: String, json: String): Uri {
        val budget = call { drive.createBudget(fileName, json) }
        remember(budget)
        return Uri.fromFile(File(checkNotNull(budget.localPath) { "The new budget has no local copy." }))
    }

    fun isCloudBudget(uri: Uri): Boolean =
        uri.scheme == "file" && uri.path?.let { drive.isCloudPath(it) } == true

    /** Syncs the working copy at [uri] after a save; other URIs are ignored. */
    fun sync(uri: Uri) {
        if (uri.scheme != "file") return
        val id = uri.path?.let { drive.budgetIdForPath(it) } ?: return
        scheduler.request(id)
    }

    private suspend fun syncNow(id: String) {
        try {
            val result = call { drive.syncBudget(id) }
            remember(result.budget)
            _state.update { it.copy(error = null) }
            if (result.localChanged) {
                _changes.emit(Uri.fromFile(File(result.localPath)))
            }
        } catch (error: CloudException) {
            // Sync runs again after the next save or timer tick.
            _state.update { it.copy(error = error.message) }
            if (error.requiresSignIn) publishAccount()
        }
    }

    fun budget(uri: Uri): BWCloudBudget? {
        val id = uri.takeIf { it.scheme == "file" }?.path?.let { drive.budgetIdForPath(it) } ?: return null
        return _state.value.budgets.firstOrNull { it.id == id }
    }

    private fun remember(budget: BWCloudBudget) {
        _state.update { state ->
            val known = state.budgets.any { it.id == budget.id }
            state.copy(
                budgets = if (known) {
                    state.budgets.map { if (it.id == budget.id) budget else it }
                } else {
                    listOf(budget) + state.budgets
                },
            )
        }
    }

    // Sharing

    suspend fun share(budget: BWCloudBudget, email: String, canEdit: Boolean, message: String?) {
        val role = if (canEdit) BWCloudShareRole.WRITER else BWCloudShareRole.READER
        call { drive.shareBudget(budget.id, email, role, message?.takeIf { it.isNotBlank() }) }
        remember(budget.copy(isShared = true))
    }

    suspend fun shares(budget: BWCloudBudget): List<BWCloudShare> = call { drive.listShares(budget.id) }

    suspend fun removeShare(budget: BWCloudBudget, share: BWCloudShare) {
        call { drive.removeShare(budget.id, share.id) }
    }

    /** Runs a blocking core call off the main thread with readable errors. */
    private suspend fun <T> call(work: () -> T): T = withContext(Dispatchers.IO) {
        try {
            work()
        } catch (error: Exception) {
            val raw = error.message ?: error.toString()
            throw CloudException(cloudErrorMessage(raw), isCloudSignInRequired(raw))
        }
    }

    private companion object {
        const val PREFERENCES_NAME = "budget_warden_google_drive"
    }
}

/** Access tokens from Google Play services. Called from core threads only. */
private class PlayServicesTokenSource(private val context: Context) : BWGoogleTokenSource {
    private val client: AuthorizationClient = Identity.getAuthorizationClient(context)
    private val request = AuthorizationRequest.builder()
        .setRequestedScopes(listOf(Scope(DRIVE_SCOPE)))
        .build()

    @Volatile private var lastToken: String? = null

    fun authorize() = client.authorize(request)

    fun resultFromIntent(data: Intent?): AuthorizationResult = client.getAuthorizationResultFromIntent(data)

    override fun accessToken(forceRefresh: Boolean): String? {
        if (forceRefresh) forget()
        val result = Tasks.await(client.authorize(request), 30, TimeUnit.SECONDS)
        // A pending intent means the user must approve access again.
        if (result.hasResolution()) return null
        return result.accessToken.also { lastToken = it }
    }

    /** Drops the cached token so Play services issues a fresh one. */
    fun forget() {
        val token = lastToken ?: return
        lastToken = null
        runCatching { GoogleAuthUtil.clearToken(context, token) }
    }

    private companion object {
        const val DRIVE_SCOPE = "https://www.googleapis.com/auth/drive.file"
    }
}

/**
 * Keeps the account name the core records. Play services holds the tokens,
 * so nothing secret is stored here.
 */
private class PreferencesCredentialStore(private val preferences: SharedPreferences) : BWGoogleCredentialStore {
    override fun loadCredentials(): String? = preferences.getString(KEY, null)

    override fun saveCredentials(credentials: String) {
        check(preferences.edit().putString(KEY, credentials).commit()) { "Could not save the Google account." }
    }

    override fun deleteCredentials() {
        preferences.edit().remove(KEY).apply()
    }

    private companion object {
        const val KEY = "google_account"
    }
}
