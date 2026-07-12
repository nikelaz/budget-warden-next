package com.lazarovco.budgetwarden

import android.net.Uri
import android.os.Bundle
import android.app.Activity
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.result.IntentSenderRequest
import androidx.compose.foundation.background
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonMenu
import androidx.compose.material3.FloatingActionButtonMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.ToggleFloatingActionButton
import androidx.compose.material3.ToggleFloatingActionButtonDefaults.animateIcon
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.inset
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.zIndex
import com.lazarovco.budgetwarden.data.BudgetRepository
import com.lazarovco.budgetwarden.data.DriveAuthorization
import com.lazarovco.budgetwarden.data.DriveAuthorizer
import com.lazarovco.budgetwarden.data.VaultPreferences
import com.lazarovco.budgetwarden.data.VaultSyncEngine
import com.lazarovco.budgetwarden.data.VaultSyncWorker
import com.lazarovco.budgetwarden.data.VaultType
import com.lazarovco.budgetwarden.domain.AmountMode
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.BudgetDates
import com.lazarovco.budgetwarden.domain.BudgetRebaseOperation
import com.lazarovco.budgetwarden.domain.Category
import com.lazarovco.budgetwarden.domain.CategoryType
import com.lazarovco.budgetwarden.domain.Money
import com.lazarovco.budgetwarden.domain.ReportingSummary
import com.lazarovco.budgetwarden.domain.TemplateSelection
import com.lazarovco.budgetwarden.domain.Transaction
import com.lazarovco.budgetwarden.domain.TransactionListItem
import com.lazarovco.budgetwarden.ui.theme.BudgetWardenAndroidTheme
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.util.Currency
import java.util.Date
import java.util.Locale
import kotlin.math.cos
import kotlin.math.sin

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            BudgetWardenAndroidTheme {
                BudgetWardenAndroidApp()
            }
        }
    }
}

@Composable
fun BudgetWardenAndroidApp() {
    val context = androidx.compose.ui.platform.LocalContext.current
    val activity = context as ComponentActivity
    val repository = remember { BudgetRepository(context) }
    val snackbarHostState = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val preferences = remember { context.getSharedPreferences("budget_warden", android.content.Context.MODE_PRIVATE) }
    val vaultPreferences = remember { VaultPreferences(context) }
    val driveAuthorizer = remember(activity) { DriveAuthorizer(activity) }

    var storedBudgets by remember { mutableStateOf(repository.loadStoredBudgets()) }
    val budgets = storedBudgets.map { it.budget }
    val budgetStorage = storedBudgets.associate { it.budget.id to it.storage }
    var selectedBudgetId by rememberSaveable {
        mutableStateOf(
            preferences.getString("last_opened_budget_id", null)
                ?.takeIf { id -> budgets.any { it.id == id } }
                ?: budgets.firstOrNull()?.id,
        )
    }
    var selectedTab by rememberSaveable { mutableStateOf(AppDestination.BUDGET) }
    var transactionSearchActive by rememberSaveable { mutableStateOf(false) }
    var transactionSearchText by rememberSaveable { mutableStateOf("") }
    var currencyCode by rememberSaveable {
        mutableStateOf(preferences.getString("currency_code", null) ?: defaultCurrencyCode())
    }
    var createBudgetOpen by rememberSaveable { mutableStateOf(false) }
    var categoryEditor by remember { mutableStateOf<CategoryEditor?>(null) }
    var transactionEditor by remember { mutableStateOf<TransactionEditor?>(null) }
    var deleteTransaction by remember { mutableStateOf<TransactionListItem?>(null) }
    var deleteCategory by remember { mutableStateOf<Category?>(null) }
    var deleteBudget by remember { mutableStateOf<BudgetRepository.StoredBudget?>(null) }
    var shareBudget by remember { mutableStateOf<BudgetRepository.StoredBudget?>(null) }
    var exportBudget by remember { mutableStateOf<Budget?>(null) }
    var driveAccount by remember { mutableStateOf(vaultPreferences.accountEmail) }
    var driveConnected by remember { mutableStateOf(vaultPreferences.driveConnected) }
    var driveToken by remember { mutableStateOf<String?>(null) }
    var driveConnecting by remember { mutableStateOf(false) }

    fun showError(message: String) {
        scope.launch { snackbarHostState.showSnackbar(message) }
    }

    fun acceptAuthorization(result: DriveAuthorization) {
        when (result) {
            is DriveAuthorization.Authorized -> {
                driveConnecting = false
                driveToken = result.token
                driveConnected = true
                vaultPreferences.driveConnected = true
                driveAccount = result.email
                vaultPreferences.accountEmail = result.email
                vaultPreferences.vaultType = VaultType.GOOGLE_DRIVE
                VaultSyncWorker.enqueue(context)
            }
            is DriveAuthorization.NeedsResolution -> Unit
        }
    }

    val driveAuthorizationLauncher = rememberLauncherForActivityResult(ActivityResultContracts.StartIntentSenderForResult()) { result ->
        if (result.resultCode != Activity.RESULT_OK || result.data == null) {
            driveConnecting = false
            showError("Google Drive connection was cancelled.")
        } else {
            runCatching { driveAuthorizer.resultFromIntent(result.data!!) }
                .onSuccess(::acceptAuthorization)
                .onFailure {
                    driveConnecting = false
                    showError(it.message ?: "Google Drive connection failed.")
                }
        }
    }

    fun connectDrive(interactive: Boolean = true) {
        if (driveConnecting) return
        driveConnecting = true
        scope.launch {
            runCatching { driveAuthorizer.authorize(driveAccount) }.onSuccess { result ->
                when (result) {
                    is DriveAuthorization.Authorized -> acceptAuthorization(result)
                    is DriveAuthorization.NeedsResolution -> if (interactive) {
                        driveAuthorizationLauncher.launch(IntentSenderRequest.Builder(result.pendingIntent.intentSender).build())
                    } else {
                        driveConnecting = false
                        driveConnected = false
                        vaultPreferences.driveConnected = false
                    }
                }
            }.onFailure {
                driveConnecting = false
                if (!interactive) {
                    driveConnected = false
                    vaultPreferences.driveConnected = false
                }
                showError(it.message ?: "Google Drive connection failed.")
            }
        }
    }

    fun reload(select: String? = selectedBudgetId) {
        storedBudgets = repository.loadStoredBudgets()
        selectedBudgetId = select?.takeIf { id -> storedBudgets.any { it.budget.id == id } }
        preferences.edit()
            .putString("last_opened_budget_id", selectedBudgetId)
            .apply()
    }

    fun saveUpdatedBudget(budget: Budget, operation: BudgetRebaseOperation) {
        val saved = repository.saveBudget(budget, budgetStorage[budget.id] ?: VaultType.LOCAL, operation)
        reload(saved.id)
    }

    LaunchedEffect(driveConnected) {
        if (driveConnected) connectDrive(interactive = false)
    }

    LaunchedEffect(Unit) {
        while (isActive) {
            delay(5_000)
            reload()
        }
    }

    val importLauncher = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
        if (uri != null) {
            runCatching { repository.importBudget(uri) }
                .onSuccess { imported -> reload(imported.id) }
                .onFailure { showError(it.message ?: "Could not import budget.") }
        }
    }

    val exportLauncher = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/json")) { uri: Uri? ->
        val budget = exportBudget
        exportBudget = null
        if (uri != null && budget != null) {
            runCatching { repository.exportBudget(budget, uri) }
                .onSuccess { scope.launch { snackbarHostState.showSnackbar("Budget exported.") } }
                .onFailure { showError(it.message ?: "Could not export budget.") }
        }
    }

    val selectedBudget = budgets.firstOrNull { it.id == selectedBudgetId }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
    ) { outerPadding ->
        if (selectedBudget == null) {
            BudgetListScreen(
                storedBudgets = storedBudgets,
                modifier = Modifier.padding(outerPadding),
                onCreateBudget = { createBudgetOpen = true },
                onImportBudget = { importLauncher.launch(arrayOf("*/*")) },
                onSelectBudget = {
                    selectedBudgetId = it.id
                    preferences.edit().putString("last_opened_budget_id", it.id).apply()
                },
                onDeleteBudget = { budget, storage -> deleteBudget = BudgetRepository.StoredBudget(budget, storage) },
                onShareBudget = { budget -> shareBudget = BudgetRepository.StoredBudget(budget, VaultType.GOOGLE_DRIVE) },
            )
        } else {
            NavigationSuiteScaffold(
                navigationSuiteItems = {
                    AppDestination.entries.forEach { destination ->
                        item(
                            icon = {
                                androidx.compose.material3.Icon(
                                    painter = painterResource(destination.icon),
                                    contentDescription = destination.label,
                                )
                            },
                            label = { Text(destination.label) },
                            selected = destination == selectedTab,
                            onClick = {
                                selectedTab = destination
                                if (destination != AppDestination.TRANSACTIONS) {
                                    transactionSearchActive = false
                                    transactionSearchText = ""
                                }
                            },
                        )
                    }
                },
                modifier = Modifier
                    .padding(outerPadding)
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surfaceContainer),
            ) {
                Scaffold(
                    topBar = {
                        WorkspaceHeader(
                            budget = selectedBudget,
                            budgets = budgets,
                            searchAvailable = selectedTab == AppDestination.TRANSACTIONS,
                            searchActive = transactionSearchActive,
                            searchText = transactionSearchText,
                            onSearchActiveChange = { active ->
                                transactionSearchActive = active
                                if (!active) transactionSearchText = ""
                            },
                            onSearchTextChange = { transactionSearchText = it },
                            onAllBudgets = { selectedBudgetId = null },
                            onCreateBudget = { createBudgetOpen = true },
                            onSelectBudget = {
                                selectedBudgetId = it.id
                                preferences.edit().putString("last_opened_budget_id", it.id).apply()
                            },
                            onShareBudget = {
                                shareBudget = BudgetRepository.StoredBudget(selectedBudget, VaultType.GOOGLE_DRIVE)
                            },
                        )
                    },
                    floatingActionButton = {
                        WorkspaceFab(
                            tab = selectedTab,
                            canCreateTransaction = selectedBudget.categories.isNotEmpty(),
                            onCreateBudget = { createBudgetOpen = true },
                            onCreateCategory = {
                                categoryEditor = CategoryEditor.Create(
                                    categoryType = CategoryType.EXPENSES,
                                    typeSelectionEnabled = true,
                                )
                            },
                            onCreateTransaction = {
                                transactionEditor = TransactionEditor.Create(selectedBudget.orderedCategories().firstOrNull()?.id)
                            },
                        )
                    },
                ) { innerPadding ->
                    when (selectedTab) {
                        AppDestination.BUDGET -> BudgetDetailScreen(
                            budget = selectedBudget,
                            currencyCode = currencyCode,
                            modifier = Modifier.padding(innerPadding),
                            onCreateCategory = { categoryEditor = CategoryEditor.Create(it) },
                            onEditCategory = { categoryEditor = CategoryEditor.Edit(it) },
                            onDeleteCategory = { category -> deleteCategory = category },
                            onReorderCategory = { type, orderedCategories ->
                                saveUpdatedBudget(
                                    selectedBudget.reorderCategories(type, orderedCategories),
                                    BudgetRebaseOperation.CategoriesBulkOrdinalUpdate(orderedCategories.map { it.id }),
                                )
                            },
                        )

                        AppDestination.REPORTING -> ReportingScreen(
                            budget = selectedBudget,
                            currencyCode = currencyCode,
                            modifier = Modifier.padding(innerPadding),
                        )

                        AppDestination.TRANSACTIONS -> TransactionsScreen(
                            budget = selectedBudget,
                            currencyCode = currencyCode,
                            searchText = transactionSearchText,
                            modifier = Modifier.padding(innerPadding),
                            onEditTransaction = { transactionEditor = TransactionEditor.Edit(it) },
                            onDeleteTransaction = { deleteTransaction = it },
                        )

                        AppDestination.SETTINGS -> SettingsScreen(
                            budget = selectedBudget,
                            currencyCode = currencyCode,
                            driveAccount = driveAccount,
                            driveConnected = driveConnected,
                            driveConnecting = driveConnecting,
                            isGoogleDriveBudget = budgetStorage[selectedBudget.id] == VaultType.GOOGLE_DRIVE,
                            modifier = Modifier.padding(innerPadding),
                            onCurrencyChange = {
                                currencyCode = it
                                preferences.edit().putString("currency_code", it).apply()
                            },
                            onRenameBudget = { title ->
                                saveUpdatedBudget(selectedBudget.copy(title = title.trim()), BudgetRebaseOperation.BudgetUpdate)
                            },
                            onExportBudget = {
                                exportBudget = selectedBudget
                                exportLauncher.launch(repository.normalizedFileName(selectedBudget.title))
                            },
                            onDeleteBudget = {
                                deleteBudget = BudgetRepository.StoredBudget(
                                    selectedBudget,
                                    budgetStorage[selectedBudget.id] ?: VaultType.LOCAL,
                                )
                            },
                            onConnectDrive = { connectDrive(interactive = true) },
                            onShareBudget = {
                                shareBudget = BudgetRepository.StoredBudget(selectedBudget, VaultType.GOOGLE_DRIVE)
                            },
                        )
                    }
                }
            }
        }
    }

    if (createBudgetOpen) {
        CreateBudgetDialog(
            budgets = budgets,
            initialStorage = if (driveConnected) VaultType.GOOGLE_DRIVE else VaultType.LOCAL,
            driveConnected = driveConnected,
            onGoogleDriveSelected = { if (!driveConnected) connectDrive(interactive = true) },
            onDismiss = { createBudgetOpen = false },
            onCreate = { title, template, previous, storage ->
                runCatching { repository.createBudget(title, template, previous, storage) }
                    .onSuccess { budget ->
                        createBudgetOpen = false
                        reload(budget.id)
                        if (storage == VaultType.GOOGLE_DRIVE && !driveConnected) connectDrive(interactive = true)
                    }
                    .onFailure { showError("Enter a budget name before creating it.") }
            },
        )
    }

    categoryEditor?.let { editor ->
        CategoryDialog(
            editor = editor,
            onDismiss = { categoryEditor = null },
            onSave = { title, amount, type ->
                val budget = selectedBudget ?: return@CategoryDialog
                val cents = Money.parse(amount) ?: return@CategoryDialog
                val updated = when (editor) {
                    is CategoryEditor.Create -> budget.addCategory(title, cents, type)
                    is CategoryEditor.Edit -> budget.updateCategory(editor.category.copy(
                        title = title.trim(),
                        amountPlanned = cents,
                        categoryType = type,
                    ))
                }
                categoryEditor = null
                val operation = when (editor) {
                    is CategoryEditor.Create -> BudgetRebaseOperation.CategoryCreate(
                        updated.categories.first { candidate -> budget.categories.none { it.id == candidate.id } }.id,
                    )
                    is CategoryEditor.Edit -> BudgetRebaseOperation.CategoryUpdate(editor.category.id)
                }
                saveUpdatedBudget(updated, operation)
            },
            onDelete = {
                if (editor is CategoryEditor.Edit) {
                    categoryEditor = null
                    deleteCategory = editor.category
                }
            },
        )
    }

    deleteCategory?.let { category ->
        val budget = selectedBudget
        if (budget != null) {
            AlertDialog(
                onDismissRequest = { deleteCategory = null },
                title = { Text(stringResource(R.string.delete_category_title)) },
                text = { Text(stringResource(R.string.delete_category_message, category.title)) },
                confirmButton = {
                    TextButton(
                        onClick = {
                            deleteCategory = null
                            saveUpdatedBudget(
                                budget.copy(categories = budget.categories.filterNot { it.id == category.id }),
                                BudgetRebaseOperation.CategoryDelete(category.id),
                            )
                        },
                    ) { Text(stringResource(R.string.delete_category)) }
                },
                dismissButton = {
                    TextButton(onClick = { deleteCategory = null }) { Text(stringResource(R.string.cancel)) }
                },
            )
        }
    }

    transactionEditor?.let { editor ->
        val budget = selectedBudget
        if (budget != null) {
            TransactionDialog(
                editor = editor,
                categories = budget.orderedCategories(),
                onDismiss = { transactionEditor = null },
                onSave = { categoryId, title, description, dateText, amountText ->
                    val amount = Money.parse(amountText) ?: return@TransactionDialog
                    val date = BudgetDates.parseInput(dateText) ?: return@TransactionDialog
                    val updated = when (editor) {
                        is TransactionEditor.Create -> budget.addTransaction(categoryId, title, description, date, amount)
                        is TransactionEditor.Edit -> budget.updateTransaction(
                            editor.item,
                            categoryId,
                            Transaction(
                                id = editor.item.transaction.id,
                                title = title.trim(),
                                description = description.trim(),
                                date = date,
                                amount = amount,
                            ),
                        )
                    }
                    transactionEditor = null
                    val operation = when (editor) {
                        is TransactionEditor.Create -> BudgetRebaseOperation.TransactionCreate(
                            categoryId,
                            updated.categories.first { it.id == categoryId }.transactions.last().id,
                        )
                        is TransactionEditor.Edit -> BudgetRebaseOperation.TransactionUpdate(
                            editor.item.category.id,
                            categoryId,
                            editor.item.transaction.id,
                        )
                    }
                    saveUpdatedBudget(updated, operation)
                },
                onDelete = {
                    if (editor is TransactionEditor.Edit) {
                        transactionEditor = null
                        deleteTransaction = editor.item
                    }
                },
            )
        }
    }

    deleteTransaction?.let { item ->
        val budget = selectedBudget
        if (budget != null) {
            AlertDialog(
                onDismissRequest = { deleteTransaction = null },
                title = { Text(stringResource(R.string.delete_transaction_title)) },
                text = { Text(stringResource(R.string.delete_transaction_message, item.transaction.title)) },
                confirmButton = {
                    TextButton(onClick = {
                        deleteTransaction = null
                        saveUpdatedBudget(
                            budget.deleteTransaction(item),
                            BudgetRebaseOperation.TransactionDelete(item.category.id, item.transaction.id),
                        )
                    }) { Text(stringResource(R.string.delete_transaction)) }
                },
                dismissButton = {
                    TextButton(onClick = { deleteTransaction = null }) { Text(stringResource(R.string.cancel)) }
                },
            )
        }
    }

    deleteBudget?.let { stored ->
        val budget = stored.budget
        AlertDialog(
            onDismissRequest = { deleteBudget = null },
            title = { Text(stringResource(R.string.delete_budget_title)) },
            text = {
                Text(
                    if (stored.storage == VaultType.GOOGLE_DRIVE) {
                        "\"${budget.title}\" will be removed from Google Drive."
                    } else {
                        stringResource(R.string.delete_budget_message, budget.title)
                    },
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        repository.deleteBudget(budget, stored.storage)
                        deleteBudget = null
                        reload()
                    },
                ) { Text(stringResource(R.string.delete_budget)) }
            },
            dismissButton = {
                TextButton(onClick = { deleteBudget = null }) { Text(stringResource(R.string.cancel)) }
            },
        )
    }

    shareBudget?.let { stored ->
        ShareBudgetDialog(
            budget = stored.budget,
            onDismiss = { shareBudget = null },
            onShare = { email ->
                val token = driveToken
                if (token == null) {
                    connectDrive(interactive = true)
                    showError("Connect Google Drive, then try sharing again.")
                } else {
                    scope.launch {
                        runCatching { VaultSyncEngine(context).share(stored.budget.id, email, token) }
                            .onSuccess {
                                shareBudget = null
                                snackbarHostState.showSnackbar("Budget shared with $email.")
                            }
                            .onFailure { showError(it.message ?: "Could not share budget.") }
                    }
                }
            },
        )
    }
}

private enum class AppDestination(val label: String, val icon: Int) {
    BUDGET("Budget", R.drawable.ic_wallet),
    REPORTING("Reporting", R.drawable.ic_bar_chart),
    TRANSACTIONS("Transactions", R.drawable.ic_receipt),
    SETTINGS("Settings", R.drawable.ic_settings),
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BudgetListScreen(
    storedBudgets: List<BudgetRepository.StoredBudget>,
    modifier: Modifier = Modifier,
    onCreateBudget: () -> Unit,
    onImportBudget: () -> Unit,
    onSelectBudget: (Budget) -> Unit,
    onDeleteBudget: (Budget, VaultType) -> Unit,
    onShareBudget: (Budget) -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(stringResource(R.string.budgets)) },
                actions = {
                    TextButton(onClick = onImportBudget) {
                        Icon(painterResource(R.drawable.ic_import), contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(stringResource(R.string.import_budget))
                    }
                },
            )
        },
        floatingActionButton = {
            FloatingActionButton(onClick = onCreateBudget) {
                Icon(
                    painter = painterResource(R.drawable.ic_add),
                    contentDescription = stringResource(R.string.new_budget),
                )
            }
        },
        modifier = modifier.fillMaxSize(),
    ) { innerPadding ->
        if (storedBudgets.isEmpty()) {
            EmptyState(
                title = "No Budgets",
                message = "Create a budget and choose where it should be stored.",
                modifier = Modifier.padding(innerPadding),
            )
        } else {
            LazyColumn(
                modifier = Modifier
                    .padding(innerPadding)
                    .fillMaxSize(),
                contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
                verticalArrangement = Arrangement.spacedBy(14.dp),
            ) {
                listOf(VaultType.GOOGLE_DRIVE to "Google Drive", VaultType.LOCAL to "Local").forEach { (storage, heading) ->
                    val section = storedBudgets.filter { it.storage == storage }
                    if (section.isNotEmpty()) {
                        item(key = "heading-$storage") {
                            Text(heading, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                        }
                        items(section, key = { "${storage.name}-${it.budget.id}" }) { stored ->
                            BudgetRow(
                                budget = stored.budget,
                                canShare = stored.storage == VaultType.GOOGLE_DRIVE,
                                onSelect = { onSelectBudget(stored.budget) },
                                onDelete = { onDeleteBudget(stored.budget, stored.storage) },
                                onShare = { onShareBudget(stored.budget) },
                            )
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BudgetRow(
    budget: Budget,
    canShare: Boolean,
    onSelect: () -> Unit,
    onDelete: () -> Unit,
    onShare: () -> Unit,
) {
    val rowShape = RoundedCornerShape(8.dp)
    val dismissState = rememberSwipeToDismissBoxState()
    LaunchedEffect(dismissState.currentValue) {
        if (dismissState.currentValue == SwipeToDismissBoxValue.EndToStart) {
            onDelete()
            dismissState.snapTo(SwipeToDismissBoxValue.Settled)
        }
    }

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(rowShape)
                    .background(MaterialTheme.colorScheme.errorContainer)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(
                    text = stringResource(R.string.delete_budget),
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        },
        modifier = Modifier.fillMaxWidth(),
    ) {
        var actionsExpanded by remember { mutableStateOf(false) }

        Card(
            modifier = Modifier
                .fillMaxWidth()
                .clip(rowShape)
                .clickable(onClick = onSelect),
            shape = rowShape,
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        ) {
            Row(
                modifier = Modifier.padding(start = 12.dp, top = 10.dp, end = 4.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = budget.title,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Box {
                    IconButton(onClick = { actionsExpanded = true }) {
                        Icon(
                            painter = painterResource(R.drawable.ic_more_vert),
                            contentDescription = stringResource(R.string.budget_actions),
                        )
                    }
                    DropdownMenu(expanded = actionsExpanded, onDismissRequest = { actionsExpanded = false }) {
                        if (canShare) {
                            DropdownMenuItem(
                                text = { Text(stringResource(R.string.share_budget)) },
                                leadingIcon = { Icon(painterResource(R.drawable.ic_share), contentDescription = null) },
                                onClick = {
                                    actionsExpanded = false
                                    onShare()
                                },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete_budget)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_delete), contentDescription = null) },
                            onClick = {
                                actionsExpanded = false
                                onDelete()
                            },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun WorkspaceHeader(
    budget: Budget,
    budgets: List<Budget>,
    searchAvailable: Boolean,
    searchActive: Boolean,
    searchText: String,
    onSearchActiveChange: (Boolean) -> Unit,
    onSearchTextChange: (String) -> Unit,
    onAllBudgets: () -> Unit,
    onCreateBudget: () -> Unit,
    onSelectBudget: (Budget) -> Unit,
    onShareBudget: () -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }
    val searchFocusRequester = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    LaunchedEffect(searchActive) {
        if (searchActive) searchFocusRequester.requestFocus()
    }
    TopAppBar(
        navigationIcon = {
            IconButton(onClick = if (searchActive) { { onSearchActiveChange(false) } } else onAllBudgets) {
                Icon(
                    painter = painterResource(if (searchActive) R.drawable.ic_arrow_back else R.drawable.ic_list),
                    contentDescription = stringResource(if (searchActive) R.string.close_search else R.string.all_budgets),
                )
            }
        },
        title = {
            if (searchActive) {
                TextField(
                    value = searchText,
                    onValueChange = onSearchTextChange,
                    placeholder = { Text(stringResource(R.string.search_transactions)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(imeAction = ImeAction.Search),
                    keyboardActions = KeyboardActions(onSearch = { focusManager.clearFocus() }),
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Transparent,
                        unfocusedContainerColor = Color.Transparent,
                        focusedIndicatorColor = Color.Transparent,
                        unfocusedIndicatorColor = Color.Transparent,
                    ),
                    modifier = Modifier.fillMaxWidth().focusRequester(searchFocusRequester),
                )
            } else Box {
                TextButton(onClick = { expanded = true }) {
                    Text(
                        text = budget.title,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded)
                }
                DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                    budgets.forEach { item ->
                        DropdownMenuItem(
                            text = { Text(item.title) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_wallet), contentDescription = null) },
                            onClick = { expanded = false; onSelectBudget(item) },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text(stringResource(R.string.new_budget)) },
                        leadingIcon = { Icon(painterResource(R.drawable.ic_add), contentDescription = null) },
                        onClick = { expanded = false; onCreateBudget() },
                    )
                }
            }
        },
        actions = {
            when {
                searchActive && searchText.isNotEmpty() -> IconButton(onClick = { onSearchTextChange("") }) {
                    Icon(painterResource(R.drawable.ic_close), contentDescription = stringResource(R.string.clear_search))
                }
                searchAvailable && !searchActive -> IconButton(onClick = { onSearchActiveChange(true) }) {
                    Icon(painterResource(R.drawable.ic_search), contentDescription = stringResource(R.string.search_transactions))
                }
            }
            IconButton(onClick = onShareBudget) {
                Icon(
                    painter = painterResource(R.drawable.ic_share),
                    contentDescription = stringResource(R.string.share_budget),
                )
            }
        },
    )
}

@OptIn(ExperimentalMaterial3ExpressiveApi::class)
@Composable
private fun WorkspaceFab(
    tab: AppDestination,
    canCreateTransaction: Boolean,
    onCreateBudget: () -> Unit,
    onCreateCategory: () -> Unit,
    onCreateTransaction: () -> Unit,
) {
    var expanded by rememberSaveable { mutableStateOf(false) }

    when (tab) {
        AppDestination.BUDGET -> FloatingActionButtonMenu(
            expanded = expanded,
            button = {
                ToggleFloatingActionButton(
                    checked = expanded,
                    onCheckedChange = { expanded = it },
                ) {
                    Icon(
                        painter = painterResource(if (checkedProgress > 0.5f) R.drawable.ic_close else R.drawable.ic_add),
                        contentDescription = stringResource(if (expanded) R.string.close_add_menu else R.string.add),
                        modifier = Modifier.animateIcon(checkedProgress = { checkedProgress }),
                    )
                }
            },
        ) {
            FloatingActionButtonMenuItem(
                text = { Text(stringResource(R.string.category)) },
                icon = { Icon(painterResource(R.drawable.ic_list), contentDescription = null) },
                onClick = {
                    expanded = false
                    onCreateCategory()
                },
            )
            FloatingActionButtonMenuItem(
                text = { Text(stringResource(R.string.transaction)) },
                icon = { Icon(painterResource(R.drawable.ic_receipt), contentDescription = null) },
                onClick = {
                    if (canCreateTransaction) {
                        expanded = false
                        onCreateTransaction()
                    }
                },
                contentColor = if (canCreateTransaction) MaterialTheme.colorScheme.onPrimaryContainer else MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f),
            )
            FloatingActionButtonMenuItem(
                text = { Text(stringResource(R.string.budget)) },
                icon = { Icon(painterResource(R.drawable.ic_wallet), contentDescription = null) },
                onClick = {
                    expanded = false
                    onCreateBudget()
                },
            )
        }
        AppDestination.TRANSACTIONS -> FloatingActionButton(
            onClick = onCreateTransaction,
            modifier = Modifier,
        ) {
            Icon(
                painter = painterResource(R.drawable.ic_add),
                contentDescription = stringResource(R.string.new_transaction),
            )
        }
        else -> Unit
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun BudgetDetailScreen(
    budget: Budget,
    currencyCode: String,
    modifier: Modifier = Modifier,
    onCreateCategory: (CategoryType) -> Unit,
    onEditCategory: (Category) -> Unit,
    onDeleteCategory: (Category) -> Unit,
    onReorderCategory: (CategoryType, List<Category>) -> Unit,
) {
    var mode by rememberSaveable { mutableStateOf(AmountMode.PLANNED) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current
    var displayOrders by remember(budget.id) { mutableStateOf<Map<CategoryType, List<Category>>>(emptyMap()) }
    var draggedCategoryId by remember { mutableStateOf<String?>(null) }
    var draggedCategoryType by remember { mutableStateOf<CategoryType?>(null) }
    var dragOffset by remember { mutableStateOf(0f) }

    LaunchedEffect(budget.categories) {
        if (draggedCategoryId == null) {
            displayOrders = emptyMap()
        }
    }

    fun displayedCategories(type: CategoryType): List<Category> =
        displayOrders[type] ?: budget.orderedCategories(type)

    fun finishDrag(commit: Boolean) {
        val type = draggedCategoryType
        val ordered = type?.let { displayOrders[it] }
        draggedCategoryId = null
        draggedCategoryType = null
        dragOffset = 0f
        if (commit && type != null && ordered != null) {
            onReorderCategory(type, ordered)
        }
        displayOrders = emptyMap()
    }

    fun updateDrag(category: Category, dragAmountY: Float) {
        val type = draggedCategoryType ?: category.categoryType
        val currentOrder = displayOrders[type] ?: budget.orderedCategories(type)
        val fromIndex = currentOrder.indexOfFirst { it.id == category.id }
        if (fromIndex < 0) return

        dragOffset += dragAmountY

        val draggedKey = categoryKey(category.id)
        val draggedInfo = listState.layoutInfo.visibleItemsInfo.firstOrNull { it.key == draggedKey } ?: return
        val draggedCenter = draggedInfo.offset + (draggedInfo.size / 2f) + dragOffset

        val visibleCategoryInfo = listState.layoutInfo.visibleItemsInfo
            .mapNotNull { itemInfo ->
                val id = categoryIdFromKey(itemInfo.key) ?: return@mapNotNull null
                val index = currentOrder.indexOfFirst { it.id == id }
                if (index >= 0 && id != category.id) {
                    ReorderItemInfo(
                        categoryId = id,
                        index = index,
                        center = itemInfo.offset + (itemInfo.size / 2f),
                        size = itemInfo.size,
                    )
                } else {
                    null
                }
            }

        val target = if (dragAmountY > 0f) {
            visibleCategoryInfo
                .filter { it.index > fromIndex && draggedCenter > it.center }
                .maxByOrNull { it.index }
        } else {
            visibleCategoryInfo
                .filter { it.index < fromIndex && draggedCenter < it.center }
                .minByOrNull { it.index }
        }

        if (target != null) {
            displayOrders = displayOrders + (type to currentOrder.moved(fromIndex, target.index))
            dragOffset += if (target.index > fromIndex) -target.size.toFloat() else target.size.toFloat()
        }

        val viewportStart = listState.layoutInfo.viewportStartOffset
        val viewportEnd = listState.layoutInfo.viewportEndOffset
        val autoscrollThreshold = with(density) { 72.dp.toPx() }
        val scrollAmount = when {
            draggedCenter < viewportStart + autoscrollThreshold -> -18f
            draggedCenter > viewportEnd - autoscrollThreshold -> 18f
            else -> 0f
        }
        if (scrollAmount != 0f) {
            scope.launch { listState.scrollBy(scrollAmount) }
        }
    }

    LazyColumn(
        modifier = modifier.fillMaxSize(),
        state = listState,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        item(key = "mode") {
            Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                SingleChoiceSegmentedButtonRow {
                    AmountMode.entries.forEachIndexed { index, item ->
                        SegmentedButton(
                            selected = mode == item,
                            onClick = { mode = item },
                            shape = SegmentedButtonDefaults.itemShape(index, AmountMode.entries.size),
                        ) { Text(item.title) }
                    }
                }
            }
        }

        CategoryType.entries.forEach { type ->
            item(key = "header-${type.rawValue}") {
                Text(type.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            }
            val categories = displayedCategories(type)
            items(categories, key = { categoryKey(it.id) }) { category ->
                val isDragging = draggedCategoryId == category.id
                CategoryRow(
                    category = category,
                    amount = mode.amount(category),
                    currencyCode = currencyCode,
                    modifier = Modifier
                        .then(if (isDragging) Modifier else Modifier.animateItem())
                        .zIndex(if (isDragging) 1f else 0f)
                        .graphicsLayer {
                            translationY = if (isDragging) dragOffset else 0f
                            scaleX = if (isDragging) 1.02f else 1f
                            scaleY = if (isDragging) 1.02f else 1f
                        },
                    onEdit = { onEditCategory(category) },
                    onDelete = { onDeleteCategory(category) },
                    onDragStart = {
                        displayOrders = displayOrders + (type to categories)
                        draggedCategoryId = category.id
                        draggedCategoryType = type
                        dragOffset = 0f
                    },
                    onDrag = { updateDrag(category, it) },
                    onDragEnd = { finishDrag(commit = true) },
                    onDragCancel = { finishDrag(commit = false) },
                )
            }
            item(key = "add-${type.rawValue}") {
                OutlinedButton(onClick = { onCreateCategory(type) }) {
                    Icon(
                        painter = painterResource(R.drawable.ic_add),
                        contentDescription = null,
                    )
                    Spacer(Modifier.width(8.dp))
                    Text(stringResource(newCategoryTitleResource(type)))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CategoryRow(
    category: Category,
    amount: Long,
    currencyCode: String,
    modifier: Modifier = Modifier,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
    onDragStart: () -> Unit,
    onDrag: (Float) -> Unit,
    onDragEnd: () -> Unit,
    onDragCancel: () -> Unit,
) {
    val rowShape = RoundedCornerShape(8.dp)
    val dismissState = rememberSwipeToDismissBoxState()
    LaunchedEffect(dismissState.currentValue) {
        if (dismissState.currentValue == SwipeToDismissBoxValue.EndToStart) {
            onDelete()
            dismissState.snapTo(SwipeToDismissBoxValue.Settled)
        }
    }

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(rowShape)
                    .background(MaterialTheme.colorScheme.errorContainer)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(
                    text = stringResource(R.string.delete_category),
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        },
        modifier = modifier.fillMaxWidth(),
    ) {
        var actionsExpanded by remember { mutableStateOf(false) }

        Card(
            modifier = Modifier
                .fillMaxWidth()
                .clip(rowShape)
                .pointerInput(category.id) {
                    detectDragGesturesAfterLongPress(
                        onDragStart = { onDragStart() },
                        onDragEnd = onDragEnd,
                        onDragCancel = onDragCancel,
                        onDrag = { change, dragAmount ->
                            change.consume()
                            onDrag(dragAmount.y)
                        },
                    )
                }
                .clickable(onClick = onEdit),
            shape = rowShape,
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        ) {
            Row(
                modifier = Modifier.padding(start = 12.dp, top = 10.dp, end = 4.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(category.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        Money.format(amount, currencyCode),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Box {
                    IconButton(onClick = { actionsExpanded = true }) {
                        Icon(
                            painter = painterResource(R.drawable.ic_more_vert),
                            contentDescription = stringResource(R.string.category_actions),
                        )
                    }
                    DropdownMenu(expanded = actionsExpanded, onDismissRequest = { actionsExpanded = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.edit_category)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_edit), contentDescription = null) },
                            onClick = {
                                actionsExpanded = false
                                onEdit()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete_category)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_delete), contentDescription = null) },
                            onClick = {
                                actionsExpanded = false
                                onDelete()
                            },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ReportingScreen(
    budget: Budget,
    currencyCode: String,
    modifier: Modifier = Modifier,
) {
    var mode by rememberSaveable { mutableStateOf(AmountMode.PLANNED) }
    val income = ReportingSummary.incomeTotal(budget)
    val savings = ReportingSummary.plannedSavingsTotal(budget)
    val expenseColor = MaterialTheme.colorScheme.error
    val savingsColor = MaterialTheme.colorScheme.tertiary
    val debtColor = MaterialTheme.colorScheme.primary
    val comparison = listOf(
        ReportingBar(stringResource(R.string.income), listOf(ReportingSlice(stringResource(R.string.income), income, savingsColor))),
        ReportingBar(stringResource(R.string.planned), listOf(
            ReportingSlice(stringResource(R.string.expenses), ReportingSummary.total(budget, setOf(CategoryType.EXPENSES), AmountMode.PLANNED), expenseColor),
            ReportingSlice(stringResource(R.string.savings), savings, savingsColor),
            ReportingSlice(stringResource(R.string.debt), ReportingSummary.total(budget, setOf(CategoryType.DEBT), AmountMode.PLANNED), debtColor),
        )),
        ReportingBar(stringResource(R.string.actual), listOf(
            ReportingSlice(stringResource(R.string.expenses), ReportingSummary.total(budget, setOf(CategoryType.EXPENSES), AmountMode.ACTUAL), expenseColor),
            ReportingSlice(stringResource(R.string.savings), ReportingSummary.total(budget, setOf(CategoryType.SAVINGS), AmountMode.ACTUAL), savingsColor),
            ReportingSlice(stringResource(R.string.debt), ReportingSummary.total(budget, setOf(CategoryType.DEBT), AmountMode.ACTUAL), debtColor),
        )),
    )
    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(30.dp),
    ) {
        Box(modifier = Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            SingleChoiceSegmentedButtonRow {
                AmountMode.entries.forEachIndexed { index, item ->
                    SegmentedButton(
                        selected = mode == item,
                        onClick = { mode = item },
                        shape = SegmentedButtonDefaults.itemShape(index, AmountMode.entries.size),
                    ) { Text(item.title) }
                }
            }
        }
        MetricGrid(budget, currencyCode)
        val charts = listOf(ReportingChart.Comparison, ReportingChart.Allocation) +
            CategoryType.entries.map(ReportingChart::CategoryBreakdown)
        ReportingChartGrid(charts = charts) { chart, chartModifier ->
            when (chart) {
                ReportingChart.Comparison -> ComparisonChart(comparison, chartModifier)
                ReportingChart.Allocation -> DonutChartSection(
                    title = stringResource(R.string.amount_allocation, mode.title),
                    emptyTitle = stringResource(R.string.no_allocation_amounts, mode.title.lowercase()),
                    segments = ReportingSummary.allocationSegments(budget, mode),
                    currencyCode = currencyCode,
                    modifier = chartModifier,
                )
                is ReportingChart.CategoryBreakdown -> DonutChartSection(
                    title = stringResource(R.string.category_breakdown, chart.type.title),
                    emptyTitle = stringResource(R.string.no_category_amounts, mode.title.lowercase(), chart.type.title.lowercase()),
                    segments = ReportingSummary.categorySegments(budget, chart.type, mode),
                    currencyCode = currencyCode,
                    modifier = chartModifier,
                )
            }
        }
    }
}

@Composable
private fun MetricGrid(budget: Budget, currencyCode: String) {
    val income = ReportingSummary.incomeTotal(budget)
    val planned = ReportingSummary.plannedSpendingTotal(budget)
    val actual = ReportingSummary.actualSpendingTotal(budget)
    val left = ReportingSummary.leftToBudgetTotal(budget)
    val metrics = listOf(
        ReportingMetric(stringResource(R.string.income), Money.format(income, currencyCode)),
        ReportingMetric(stringResource(R.string.planned_spending), Money.format(planned, currencyCode), isError = planned > income),
        ReportingMetric(stringResource(R.string.actual_spending), Money.format(actual, currencyCode), isError = actual > planned, isPositive = actual <= planned),
        ReportingMetric(stringResource(R.string.savings), Money.format(ReportingSummary.plannedSavingsTotal(budget), currencyCode)),
        ReportingMetric(stringResource(R.string.left_to_budget), Money.formatSigned(left, currencyCode), isError = left < 0),
    )
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = when {
            maxWidth >= 790.dp -> 5
            maxWidth >= 630.dp -> 4
            maxWidth >= 470.dp -> 3
            else -> 2
        }
        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            metrics.chunked(columns).forEach { rowMetrics ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    rowMetrics.forEach { metric -> MetricCard(metric, Modifier.weight(1f)) }
                    repeat(columns - rowMetrics.size) { Spacer(Modifier.weight(1f)) }
                }
            }
        }
    }
}

private data class ReportingMetric(
    val title: String,
    val value: String,
    val isError: Boolean = false,
    val isPositive: Boolean = false,
)

@Composable
private fun MetricCard(metric: ReportingMetric, modifier: Modifier = Modifier) {
    Card(
        modifier = modifier,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Column(modifier = Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text(metric.title, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            Text(
                metric.value,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = when { metric.isError -> MaterialTheme.colorScheme.error; metric.isPositive -> MaterialTheme.colorScheme.tertiary; else -> MaterialTheme.colorScheme.onSurface },
                maxLines = 1,
            )
        }
    }
}

private data class ReportingSlice(val title: String, val amount: Long, val color: Color)
private data class ReportingBar(val title: String, val slices: List<ReportingSlice>)
private sealed interface ReportingChart {
    data object Comparison : ReportingChart
    data object Allocation : ReportingChart
    data class CategoryBreakdown(val type: CategoryType) : ReportingChart
}

@Composable
private fun ReportingChartGrid(
    charts: List<ReportingChart>,
    content: @Composable (ReportingChart, Modifier) -> Unit,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = if (maxWidth >= 700.dp) 2 else 1
        Column(verticalArrangement = Arrangement.spacedBy(30.dp)) {
            charts.chunked(columns).forEach { rowCharts ->
                Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    rowCharts.forEach { chart -> content(chart, Modifier.weight(1f)) }
                    if (rowCharts.size < columns) Spacer(Modifier.weight(1f))
                }
            }
        }
    }
}

@Composable
private fun ReportingSection(title: String, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(title, style = MaterialTheme.typography.titleMedium)
        Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow)) {
            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) { content() }
        }
    }
}

@Composable
private fun ComparisonChart(bars: List<ReportingBar>, modifier: Modifier = Modifier) {
    val nonEmpty = bars.any { bar -> bar.slices.any { it.amount > 0 } }
    ReportingSection(stringResource(R.string.income_vs_allocation), modifier) {
        if (!nonEmpty) ReportingEmpty(stringResource(R.string.no_allocation_yet), 170.dp) else {
            val maximum = bars.maxOf { it.slices.sumOf(ReportingSlice::amount) }.coerceAtLeast(1)
            Column(Modifier.fillMaxWidth().height(170.dp), verticalArrangement = Arrangement.SpaceEvenly) {
                bars.forEach { bar ->
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Text(bar.title, Modifier.width(64.dp), style = MaterialTheme.typography.labelMedium)
                        Row(Modifier.weight(1f).height(24.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceVariant)) {
                            bar.slices.filter { it.amount > 0 }.forEach { slice ->
                                Box(Modifier.weight(slice.amount.toFloat() / maximum).fillMaxSize().background(slice.color))
                            }
                            val remainder = maximum - bar.slices.sumOf(ReportingSlice::amount)
                            if (remainder > 0) Spacer(Modifier.weight(remainder.toFloat() / maximum))
                        }
                    }
                }
            }
            FlowRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                bars.flatMap(ReportingBar::slices).distinctBy(ReportingSlice::title).forEach { LegendSwatch(it.title, it.color) }
            }
        }
    }
}

@Composable
private fun DonutChartSection(title: String, emptyTitle: String, segments: List<Pair<String, Long>>, currencyCode: String, modifier: Modifier = Modifier) {
    val colors = reportingPalette()
    val allocationColors = mapOf(
        "Expenses" to MaterialTheme.colorScheme.error,
        "Savings" to MaterialTheme.colorScheme.tertiary,
        "Debt" to MaterialTheme.colorScheme.primary,
    )
    val slices = segments.filter { it.second > 0 }.mapIndexed { index, item ->
        ReportingSlice(item.first, item.second, allocationColors[item.first] ?: colors[index % colors.size])
    }
    val total = slices.sumOf(ReportingSlice::amount)
    val separatorColor = MaterialTheme.colorScheme.surfaceContainerLow
    ReportingSection(title, modifier) {
        if (total == 0L) ReportingEmpty(emptyTitle, 210.dp) else {
            val description = slices.joinToString { "${it.title} ${Money.format(it.amount, currencyCode)}" }
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Canvas(Modifier.width(184.dp).height(184.dp).semantics { contentDescription = description }) {
                    val stroke = size.minDimension * .21f
                    var start = -90f
                    inset(stroke / 2f) {
                        slices.forEach { slice ->
                            val sweep = 360f * slice.amount.toFloat() / total.toFloat()
                            drawArc(slice.color, start, sweep, false, style = Stroke(stroke, cap = StrokeCap.Butt))
                            start += sweep
                        }
                        if (slices.size > 1) {
                            val innerRadius = size.minDimension / 2f - stroke / 2f
                            val outerRadius = size.minDimension / 2f + stroke / 2f
                            var boundary = -90f
                            slices.forEach { slice ->
                                val radians = Math.toRadians(boundary.toDouble())
                                val directionX = cos(radians).toFloat()
                                val directionY = sin(radians).toFloat()
                                drawLine(
                                    color = separatorColor,
                                    start = Offset(center.x + directionX * innerRadius, center.y + directionY * innerRadius),
                                    end = Offset(center.x + directionX * outerRadius, center.y + directionY * outerRadius),
                                    strokeWidth = 2.dp.toPx(),
                                    cap = StrokeCap.Butt,
                                )
                                boundary += 360f * slice.amount.toFloat() / total.toFloat()
                            }
                        }
                    }
                }
            }
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                slices.forEach { slice -> LegendRow(slice, total, currencyCode) }
            }
        }
    }
}

@Composable
private fun LegendSwatch(title: String, color: Color) = Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
    Box(Modifier.width(8.dp).height(8.dp).background(color, RoundedCornerShape(2.dp)))
    Text(title, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun LegendRow(slice: ReportingSlice, total: Long, currencyCode: String) {
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        LegendSwatch(slice.title, slice.color)
        Spacer(Modifier.weight(1f))
        Text(Money.format(slice.amount, currencyCode), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(String.format(Locale.getDefault(), "%.1f%%", slice.amount * 100.0 / total), Modifier.width(52.dp), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
private fun ReportingEmpty(title: String, height: Dp) = Box(Modifier.fillMaxWidth().height(height), contentAlignment = Alignment.Center) {
    Text(title, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
private fun reportingPalette() = listOf(
    MaterialTheme.colorScheme.primary,
    MaterialTheme.colorScheme.tertiary,
    MaterialTheme.colorScheme.error,
    MaterialTheme.colorScheme.secondary,
    MaterialTheme.colorScheme.primaryContainer,
    MaterialTheme.colorScheme.tertiaryContainer,
    MaterialTheme.colorScheme.errorContainer,
    MaterialTheme.colorScheme.secondaryContainer,
)

@Composable
private fun TransactionsScreen(
    budget: Budget,
    currencyCode: String,
    searchText: String,
    modifier: Modifier = Modifier,
    onEditTransaction: (TransactionListItem) -> Unit,
    onDeleteTransaction: (TransactionListItem) -> Unit,
) {
    val transactions = budget.transactionItems()
    val filtered = transactions.filter {
        val searchable = listOf(
            it.transaction.title,
            it.transaction.description,
            it.category.title,
            it.category.categoryType.title,
            Money.inputText(it.transaction.amount),
            Money.format(it.transaction.amount, currencyCode),
            BudgetDates.displayText(it.transaction.date),
        ).joinToString(" ")
        searchText.isBlank() || searchable.contains(searchText, ignoreCase = true)
    }

    when {
        transactions.isEmpty() -> EmptyState("No Transactions", "Add a transaction once you have at least one category.", modifier)
        filtered.isEmpty() -> EmptyState("No Matches", "Try another search.", modifier)
        else -> LazyColumn(
            modifier = modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
                items(filtered, key = { it.transaction.id }) { item ->
                    TransactionRow(
                        item = item,
                        currencyCode = currencyCode,
                        modifier = Modifier.animateItem(),
                        onEdit = { onEditTransaction(item) },
                        onDelete = { onDeleteTransaction(item) },
                    )
                }
            }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TransactionRow(
    item: TransactionListItem,
    currencyCode: String,
    modifier: Modifier = Modifier,
    onEdit: () -> Unit,
    onDelete: () -> Unit,
) {
    val rowShape = RoundedCornerShape(8.dp)
    val dismissState = rememberSwipeToDismissBoxState()
    LaunchedEffect(dismissState.currentValue) {
        if (dismissState.currentValue == SwipeToDismissBoxValue.EndToStart) {
            onDelete()
            dismissState.snapTo(SwipeToDismissBoxValue.Settled)
        }
    }

    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .clip(rowShape)
                    .background(MaterialTheme.colorScheme.errorContainer)
                    .padding(horizontal = 20.dp),
                contentAlignment = Alignment.CenterEnd,
            ) {
                Text(
                    text = stringResource(R.string.delete_transaction),
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    style = MaterialTheme.typography.labelLarge,
                )
            }
        },
        modifier = modifier.fillMaxWidth(),
    ) {
        var actionsExpanded by remember { mutableStateOf(false) }

        Card(
            modifier = Modifier.fillMaxWidth().clip(rowShape).clickable(onClick = onEdit),
            shape = rowShape,
            colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
        ) {
            Row(
                modifier = Modifier.padding(start = 12.dp, top = 10.dp, end = 4.dp, bottom = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(item.transaction.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${item.category.title} · ${BudgetDates.displayText(item.transaction.date)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Text(Money.format(item.transaction.amount, currencyCode), style = MaterialTheme.typography.bodyMedium)
                Box {
                    IconButton(onClick = { actionsExpanded = true }) {
                        Icon(
                            painter = painterResource(R.drawable.ic_more_vert),
                            contentDescription = stringResource(R.string.transaction_actions),
                        )
                    }
                    DropdownMenu(expanded = actionsExpanded, onDismissRequest = { actionsExpanded = false }) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.edit_transaction)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_edit), contentDescription = null) },
                            onClick = {
                                actionsExpanded = false
                                onEdit()
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.delete_transaction)) },
                            leadingIcon = { Icon(painterResource(R.drawable.ic_delete), contentDescription = null) },
                            onClick = {
                                actionsExpanded = false
                                onDelete()
                            },
                        )
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun SettingsScreen(
    budget: Budget,
    currencyCode: String,
    driveAccount: String?,
    driveConnected: Boolean,
    driveConnecting: Boolean,
    isGoogleDriveBudget: Boolean,
    modifier: Modifier = Modifier,
    onCurrencyChange: (String) -> Unit,
    onRenameBudget: (String) -> Unit,
    onExportBudget: () -> Unit,
    onDeleteBudget: () -> Unit,
    onConnectDrive: () -> Unit,
    onShareBudget: () -> Unit,
) {
    var title by remember(budget.id, budget.title) { mutableStateOf(budget.title) }
    var titleHadFocus by remember(budget.id) { mutableStateOf(false) }
    var expanded by rememberSaveable { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    val currencies = remember { Currency.getAvailableCurrencies().map { it.currencyCode }.sorted() }

    Column(
        modifier = modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Text("Budget Title", style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text("Name") },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { focusState ->
                    if (titleHadFocus && !focusState.isFocused) {
                        val normalized = title.trim()
                        if (normalized.isNotEmpty() && normalized != budget.title) onRenameBudget(normalized)
                    }
                    titleHadFocus = focusState.isFocused
                },
        )

        Text("Currency", style = MaterialTheme.typography.titleMedium)
        ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
            OutlinedTextField(
                value = currencyCode,
                onValueChange = {},
                readOnly = true,
                label = { Text("Currency") },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                modifier = Modifier
                    .menuAnchor()
                    .fillMaxWidth(),
            )
            ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                currencies.forEach { code ->
                    DropdownMenuItem(text = { Text(code) }, onClick = { expanded = false; onCurrencyChange(code) })
                }
            }
        }

        Text("Google Drive", style = MaterialTheme.typography.titleMedium)
        Text(
            if (driveConnected) driveAccount?.let { "Connected as $it" } ?: "Google Drive connected" else "Not connected",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (!driveConnected) {
            OutlinedButton(enabled = !driveConnecting, onClick = onConnectDrive) {
                Text(if (driveConnecting) "Connecting…" else "Connect Google Drive")
            }
        }
        Text(stringResource(R.string.actions), style = MaterialTheme.typography.titleMedium)
        if (isGoogleDriveBudget) {
            OutlinedButton(onClick = onShareBudget, modifier = Modifier.fillMaxWidth()) {
                Icon(painterResource(R.drawable.ic_share), contentDescription = null)
                Spacer(Modifier.width(8.dp))
                Text(stringResource(R.string.share_budget))
            }
        }
        OutlinedButton(onClick = onExportBudget, modifier = Modifier.fillMaxWidth()) {
            Icon(painterResource(R.drawable.ic_export), contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.export_budget))
        }
        OutlinedButton(onClick = onDeleteBudget, modifier = Modifier.fillMaxWidth()) {
            Icon(painterResource(R.drawable.ic_delete), contentDescription = null)
            Spacer(Modifier.width(8.dp))
            Text(stringResource(R.string.delete_budget))
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareBudgetDialog(
    budget: Budget,
    onDismiss: () -> Unit,
    onShare: (String) -> Unit,
) {
    var email by rememberSaveable(budget.id) { mutableStateOf("") }
    val normalizedEmail = email.trim()
    val validEmail = android.util.Patterns.EMAIL_ADDRESS.matcher(normalizedEmail).matches()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.share_budget_title, budget.title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text(stringResource(R.string.share_budget_explanation))
                OutlinedTextField(
                    value = email,
                    onValueChange = { email = it },
                    label = { Text(stringResource(R.string.share_email)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        },
        confirmButton = {
            TextButton(enabled = validEmail, onClick = { onShare(normalizedEmail) }) {
                Text(stringResource(R.string.share))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun CreateBudgetDialog(
    budgets: List<Budget>,
    initialStorage: VaultType,
    driveConnected: Boolean,
    onGoogleDriveSelected: () -> Unit,
    onDismiss: () -> Unit,
    onCreate: (String, TemplateSelection, Budget?, VaultType) -> Unit,
) {
    var title by rememberSaveable { mutableStateOf(currentMonthTitle()) }
    var template by rememberSaveable { mutableStateOf(TemplateSelection.BASIC) }
    var previousBudgetId by rememberSaveable { mutableStateOf(budgets.firstOrNull()?.id) }
    var templateExpanded by rememberSaveable { mutableStateOf(false) }
    var storage by rememberSaveable { mutableStateOf(initialStorage) }
    var submitted by rememberSaveable { mutableStateOf(false) }
    val titleIsValid = title.isNotBlank()
    val showTitleError = submitted && !titleIsValid
    val selectedPreviousBudget = budgets.firstOrNull { it.id == previousBudgetId }
    val templateTitle = when (template) {
        TemplateSelection.BASIC -> stringResource(R.string.basic_budget)
        TemplateSelection.BLANK -> stringResource(R.string.blank_budget)
        TemplateSelection.PREVIOUS -> selectedPreviousBudget?.title ?: stringResource(R.string.previous_budget)
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.new_budget)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text(stringResource(R.string.budget_name)) },
                    singleLine = true,
                    isError = showTitleError,
                    supportingText = if (showTitleError) {
                        { Text(stringResource(R.string.validation_budget_name_required)) }
                    } else {
                        null
                    },
                )
                Text("Storage", style = MaterialTheme.typography.labelLarge)
                SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                    listOf(VaultType.GOOGLE_DRIVE to "Google Drive", VaultType.LOCAL to "Local File")
                        .forEachIndexed { index, (option, label) ->
                            SegmentedButton(
                                selected = storage == option,
                                onClick = {
                                    storage = option
                                    if (option == VaultType.GOOGLE_DRIVE && !driveConnected) onGoogleDriveSelected()
                                },
                                shape = SegmentedButtonDefaults.itemShape(index, 2),
                            ) { Text(label) }
                        }
                }
                ExposedDropdownMenuBox(
                    expanded = templateExpanded,
                    onExpandedChange = { templateExpanded = it },
                ) {
                    OutlinedTextField(
                        value = templateTitle,
                        onValueChange = {},
                        readOnly = true,
                        singleLine = true,
                        label = { Text(stringResource(R.string.template)) },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(templateExpanded) },
                        modifier = Modifier
                            .menuAnchor()
                            .fillMaxWidth(),
                    )
                    ExposedDropdownMenu(
                        expanded = templateExpanded,
                        onDismissRequest = { templateExpanded = false },
                    ) {
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.basic_budget)) },
                            onClick = {
                                template = TemplateSelection.BASIC
                                templateExpanded = false
                            },
                        )
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.blank_budget)) },
                            onClick = {
                                template = TemplateSelection.BLANK
                                templateExpanded = false
                            },
                        )
                        DropdownMenuItem(
                            text = {
                                Text(
                                    text = stringResource(R.string.previous_budgets),
                                    style = MaterialTheme.typography.labelMedium,
                                )
                            },
                            onClick = {},
                            enabled = false,
                        )
                        budgets.forEach { budget ->
                            DropdownMenuItem(
                                text = { Text(budget.title) },
                                onClick = {
                                    previousBudgetId = budget.id
                                    template = TemplateSelection.PREVIOUS
                                    templateExpanded = false
                                },
                            )
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(
                onClick = {
                    submitted = true
                    if (titleIsValid) onCreate(title, template, selectedPreviousBudget, storage)
                },
            ) {
                Text(stringResource(R.string.create))
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
        },
    )
}

@Composable
private fun CategoryDialog(
    editor: CategoryEditor,
    onDismiss: () -> Unit,
    onSave: (String, String, CategoryType) -> Unit,
    onDelete: () -> Unit,
) {
    val initial = (editor as? CategoryEditor.Edit)?.category
    val creation = editor as? CategoryEditor.Create
    var title by rememberSaveable(editor.id) { mutableStateOf(initial?.title.orEmpty()) }
    var amount by rememberSaveable(editor.id) { mutableStateOf(Money.inputText(initial?.amountPlanned ?: 0L)) }
    var type by rememberSaveable(editor.id) { mutableStateOf(initial?.categoryType ?: creation?.categoryType ?: CategoryType.EXPENSES) }
    var submitted by rememberSaveable(editor.id) { mutableStateOf(false) }
    val typeSelectionEnabled = initial != null || creation?.typeSelectionEnabled == true
    val dialogTitle = when {
        initial != null -> R.string.edit_category
        creation?.typeSelectionEnabled == true -> R.string.new_category
        else -> newCategoryTitleResource(type)
    }
    val titleIsValid = title.isNotBlank()
    val parsedAmount = Money.parse(amount)
    val amountIsValid = parsedAmount != null
    val showTitleError = submitted && !titleIsValid
    val showAmountError = submitted && !amountIsValid

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(dialogTitle)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text(stringResource(R.string.title)) },
                    singleLine = true,
                    isError = showTitleError,
                    supportingText = if (showTitleError) {
                        { Text(stringResource(R.string.validation_category_title_required)) }
                    } else {
                        null
                    },
                )
                OutlinedTextField(
                    value = amount,
                    onValueChange = { amount = it },
                    label = { Text(stringResource(R.string.planned_amount)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    isError = showAmountError,
                    supportingText = if (showAmountError) {
                        { Text(stringResource(R.string.validation_amount_required)) }
                    } else {
                        null
                    },
                )
                if (typeSelectionEnabled) {
                    FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        CategoryType.entries.forEach { option ->
                        AssistChip(onClick = { type = option }, label = { Text(if (type == option) "${option.title} ✓" else option.title) })
                        }
                    }
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                submitted = true
                if (titleIsValid && amountIsValid) onSave(title, amount, type)
            }) { Text(stringResource(R.string.save)) }
        },
        dismissButton = {
            Row {
                if (initial != null) TextButton(onClick = onDelete) { Text(stringResource(R.string.delete_category)) }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
            }
        },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TransactionDialog(
    editor: TransactionEditor,
    categories: List<Category>,
    onDismiss: () -> Unit,
    onSave: (String, String, String, String, String) -> Unit,
    onDelete: () -> Unit,
) {
    val item = (editor as? TransactionEditor.Edit)?.item
    var categoryId by rememberSaveable(editor.id) { mutableStateOf(item?.category?.id ?: (editor as? TransactionEditor.Create)?.initialCategoryId ?: categories.firstOrNull()?.id.orEmpty()) }
    var title by rememberSaveable(editor.id) { mutableStateOf(item?.transaction?.title.orEmpty()) }
    var description by rememberSaveable(editor.id) { mutableStateOf(item?.transaction?.description.orEmpty()) }
    var dateText by rememberSaveable(editor.id) { mutableStateOf(BudgetDates.inputText(item?.transaction?.date ?: Date())) }
    var amount by rememberSaveable(editor.id) { mutableStateOf(Money.inputText(item?.transaction?.amount ?: 0L)) }
    var categoryExpanded by remember { mutableStateOf(false) }
    var detailsExpanded by rememberSaveable(editor.id) { mutableStateOf(false) }
    var datePickerVisible by remember { mutableStateOf(false) }
    var submitted by rememberSaveable(editor.id) { mutableStateOf(false) }
    val titleIsValid = title.isNotBlank()
    val amountValue = Money.parse(amount)
    val amountIsValid = amountValue != null && amountValue > 0L
    val categoryIsValid = categories.any { it.id == categoryId }
    val dateIsValid = BudgetDates.parseInput(dateText) != null
    val formIsValid = titleIsValid && amountIsValid && categoryIsValid && dateIsValid
    val showTitleError = submitted && !titleIsValid
    val showAmountError = submitted && !amountIsValid
    val showCategoryError = submitted && !categoryIsValid
    val showDateError = submitted && !dateIsValid

    if (datePickerVisible) {
        val datePickerState = rememberDatePickerState(initialSelectedDateMillis = BudgetDates.parseInput(dateText)?.time)
        DatePickerDialog(
            onDismissRequest = { datePickerVisible = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let { dateText = BudgetDates.inputText(Date(it)) }
                    datePickerVisible = false
                }) { Text(stringResource(R.string.confirm)) }
            },
            dismissButton = {
                TextButton(onClick = { datePickerVisible = false }) { Text(stringResource(R.string.cancel)) }
            },
        ) { DatePicker(state = datePickerState) }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(if (item == null) R.string.new_transaction else R.string.edit_transaction)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text(stringResource(R.string.title)) },
                    singleLine = true,
                    isError = showTitleError,
                    supportingText = if (showTitleError) {
                        { Text(stringResource(R.string.validation_transaction_title_required)) }
                    } else {
                        null
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                ExposedDropdownMenuBox(expanded = categoryExpanded, onExpandedChange = { categoryExpanded = it }) {
                    OutlinedTextField(
                        value = categories.firstOrNull { it.id == categoryId }?.title.orEmpty(),
                        onValueChange = {},
                        readOnly = true,
                        singleLine = true,
                        label = { Text(stringResource(R.string.category)) },
                        isError = showCategoryError,
                        supportingText = if (showCategoryError) {
                            { Text(stringResource(R.string.validation_category_required)) }
                        } else {
                            null
                        },
                        trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(categoryExpanded) },
                        modifier = Modifier.menuAnchor().fillMaxWidth(),
                    )
                    ExposedDropdownMenu(expanded = categoryExpanded, onDismissRequest = { categoryExpanded = false }) {
                        categories.forEach { category ->
                            DropdownMenuItem(text = { Text(category.title) }, onClick = {
                                categoryId = category.id
                                categoryExpanded = false
                            })
                        }
                    }
                }
                OutlinedTextField(
                    value = amount,
                    onValueChange = { amount = it },
                    label = { Text(stringResource(R.string.amount)) },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Decimal),
                    isError = showAmountError,
                    supportingText = if (showAmountError) {
                        { Text(stringResource(R.string.validation_positive_amount_required)) }
                    } else {
                        null
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
                TextButton(onClick = { detailsExpanded = !detailsExpanded }) {
                    Text(stringResource(if (detailsExpanded) R.string.fewer_details else R.string.more_details))
                }
                if (detailsExpanded) {
                    val selectDateDescription = stringResource(R.string.select_date)
                    Box(modifier = Modifier.fillMaxWidth()) {
                        OutlinedTextField(
                            value = BudgetDates.parseInput(dateText)?.let(BudgetDates::displayText).orEmpty(),
                            onValueChange = {},
                            readOnly = true,
                            singleLine = true,
                            label = { Text(stringResource(R.string.date)) },
                            isError = showDateError,
                            supportingText = if (showDateError) {
                                { Text(stringResource(R.string.validation_date_required)) }
                            } else {
                                null
                            },
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Box(
                            modifier = Modifier
                                .matchParentSize()
                                .clickable(role = Role.Button) { datePickerVisible = true }
                                .semantics { contentDescription = selectDateDescription },
                        )
                    }
                    OutlinedTextField(value = description, onValueChange = { description = it }, label = { Text(stringResource(R.string.description)) }, modifier = Modifier.fillMaxWidth())
                }
            }
        },
        confirmButton = {
            TextButton(onClick = {
                submitted = true
                if (formIsValid) onSave(categoryId, title, description, dateText, amount)
            }) { Text(stringResource(R.string.save)) }
        },
        dismissButton = {
            Row {
                if (item != null) TextButton(onClick = onDelete) { Text(stringResource(R.string.delete_transaction)) }
                TextButton(onClick = onDismiss) { Text(stringResource(R.string.cancel)) }
            }
        },
    )
}

@Composable
private fun EmptyState(title: String, message: String, modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(8.dp))
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

private sealed class CategoryEditor(val id: String) {
    data class Create(
        val categoryType: CategoryType,
        val typeSelectionEnabled: Boolean = false,
    ) : CategoryEditor("create-${categoryType.rawValue}-$typeSelectionEnabled")
    data class Edit(val category: Category) : CategoryEditor("edit-${category.id}")
}

private sealed class TransactionEditor(val id: String) {
    data class Create(val initialCategoryId: String?) : TransactionEditor("create-${initialCategoryId.orEmpty()}")
    data class Edit(val item: TransactionListItem) : TransactionEditor("edit-${item.transaction.id}")
}

private data class ReorderItemInfo(
    val categoryId: String,
    val index: Int,
    val center: Float,
    val size: Int,
)

private fun categoryKey(categoryId: String): String = "category-$categoryId"

private fun categoryIdFromKey(key: Any?): String? =
    (key as? String)?.takeIf { it.startsWith("category-") }?.removePrefix("category-")

private fun <T> List<T>.moved(fromIndex: Int, toIndex: Int): List<T> {
    if (fromIndex == toIndex || fromIndex !in indices || toIndex !in indices) return this
    return toMutableList().apply {
        add(toIndex, removeAt(fromIndex))
    }
}

private fun Budget.addCategory(title: String, plannedAmount: Long, type: CategoryType): Budget {
    val trimmedTitle = title.trim()
    require(trimmedTitle.isNotEmpty())
    val nextOrdinal = categories.filter { it.categoryType == type }.maxOfOrNull { it.ordinal }?.plus(1) ?: 0
    return copy(categories = categories + Category(ordinal = nextOrdinal, title = trimmedTitle, amountPlanned = plannedAmount, categoryType = type))
}

private fun Budget.updateCategory(category: Category): Budget {
    val old = categories.firstOrNull { it.id == category.id } ?: return this
    val nextOrdinal = if (old.categoryType == category.categoryType) {
        category.ordinal
    } else {
        categories.filter { it.categoryType == category.categoryType && it.id != category.id }.maxOfOrNull { it.ordinal }?.plus(1) ?: 0
    }
    val updated = categories.map { if (it.id == category.id) category.copy(title = category.title.trim(), ordinal = nextOrdinal) else it }
    return copy(categories = normalizeOrdinals(updated, old.categoryType, category.categoryType))
}

private fun Budget.reorderCategories(type: CategoryType, orderedCategories: List<Category>): Budget {
    val ordinals = orderedCategories.mapIndexed { ordinal, category -> category.id to ordinal }.toMap()
    return copy(categories = categories.map { category ->
        if (category.categoryType == type) {
            category.copy(ordinal = ordinals[category.id] ?: category.ordinal)
        } else {
            category
        }
    })
}

private fun Budget.addTransaction(categoryId: String, title: String, description: String, date: Date, amount: Long): Budget {
    val trimmedTitle = title.trim()
    require(trimmedTitle.isNotEmpty() && amount > 0L)
    return copy(categories = categories.map { category ->
        if (category.id == categoryId) {
            category.copy(transactions = category.transactions + Transaction(title = trimmedTitle, description = description.trim(), date = date, amount = amount))
        } else {
            category
        }
    })
}

private fun Budget.updateTransaction(item: TransactionListItem, destinationCategoryId: String, transaction: Transaction): Budget {
    require(transaction.title.isNotBlank() && transaction.amount > 0L)
    return copy(categories = categories.map { category ->
        when {
            category.id == item.category.id && category.id == destinationCategoryId ->
                category.copy(transactions = category.transactions.map { if (it.id == transaction.id) transaction else it })
            category.id == item.category.id ->
                category.copy(transactions = category.transactions.filterNot { it.id == transaction.id })
            category.id == destinationCategoryId ->
                category.copy(transactions = category.transactions + transaction)
            else -> category
        }
    })
}

private fun Budget.deleteTransaction(item: TransactionListItem): Budget =
    copy(categories = categories.map { category ->
        if (category.id == item.category.id) category.copy(transactions = category.transactions.filterNot { it.id == item.transaction.id }) else category
    })

private fun Budget.transactionItems(): List<TransactionListItem> =
    categories.flatMap { category -> category.transactions.map { TransactionListItem(category, it) } }
        .sortedWith(compareByDescending<TransactionListItem> { it.transaction.date }.thenBy { it.transaction.title.lowercase() })

private fun normalizeOrdinals(categories: List<Category>, vararg types: CategoryType): List<Category> {
    val ordinals = types
        .distinct()
        .flatMap { type ->
            categories
                .withIndex()
                .filter { it.value.categoryType == type }
                .sortedWith(compareBy<IndexedValue<Category>> { it.value.ordinal }.thenBy { it.index })
                .mapIndexed { ordinal, item -> item.value.id to ordinal }
        }
        .toMap()
    return categories.map { it.copy(ordinal = ordinals[it.id] ?: it.ordinal) }
}

private fun newCategoryTitleResource(type: CategoryType): Int =
    when (type) {
        CategoryType.INCOME -> R.string.new_income
        CategoryType.EXPENSES -> R.string.new_category
        CategoryType.SAVINGS -> R.string.new_fund
        CategoryType.DEBT -> R.string.new_debt
    }

private fun defaultCurrencyCode(): String =
    runCatching { Currency.getInstance(Locale.getDefault()).currencyCode }.getOrDefault("USD")

private fun currentMonthTitle(now: Date = Date()): String =
    java.text.SimpleDateFormat("LLLL yyyy", Locale.US).format(now)

@Preview(showBackground = true)
@Composable
fun BudgetWardenPreview() {
    BudgetWardenAndroidTheme {
        BudgetListScreen(
            storedBudgets = emptyList(),
            onCreateBudget = {},
            onImportBudget = {},
            onSelectBudget = {},
            onDeleteBudget = { _, _ -> },
            onShareBudget = {},
        )
    }
}
