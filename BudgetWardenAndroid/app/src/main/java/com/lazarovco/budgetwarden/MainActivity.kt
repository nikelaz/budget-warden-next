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
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExperimentalMaterial3ExpressiveApi
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.FloatingActionButtonMenu
import androidx.compose.material3.FloatingActionButtonMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TextButton
import androidx.compose.material3.ToggleFloatingActionButton
import androidx.compose.material3.ToggleFloatingActionButtonDefaults.animateIcon
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.data.BudgetRepository
import com.lazarovco.budgetwarden.data.DriveAuthorization
import com.lazarovco.budgetwarden.data.DriveAuthorizer
import com.lazarovco.budgetwarden.data.VaultPreferences
import com.lazarovco.budgetwarden.data.VaultSyncEngine
import com.lazarovco.budgetwarden.data.VaultSyncWorker
import com.lazarovco.budgetwarden.data.VaultType
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.BudgetDates
import com.lazarovco.budgetwarden.domain.BudgetRebaseOperation
import com.lazarovco.budgetwarden.domain.Category
import com.lazarovco.budgetwarden.domain.CategoryType
import com.lazarovco.budgetwarden.domain.Money
import com.lazarovco.budgetwarden.domain.Transaction
import com.lazarovco.budgetwarden.domain.TransactionListItem
import com.lazarovco.budgetwarden.ui.theme.BudgetWardenAndroidTheme
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import java.util.Currency
import java.util.Date
import java.util.Locale

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

@Composable
internal fun EmptyState(title: String, message: String, modifier: Modifier = Modifier) {
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

internal sealed class CategoryEditor(val id: String) {
    data class Create(
        val categoryType: CategoryType,
        val typeSelectionEnabled: Boolean = false,
    ) : CategoryEditor("create-${categoryType.rawValue}-$typeSelectionEnabled")
    data class Edit(val category: Category) : CategoryEditor("edit-${category.id}")
}

internal sealed class TransactionEditor(val id: String) {
    data class Create(val initialCategoryId: String?) : TransactionEditor("create-${initialCategoryId.orEmpty()}")
    data class Edit(val item: TransactionListItem) : TransactionEditor("edit-${item.transaction.id}")
}

internal data class ReorderItemInfo(
    val categoryId: String,
    val index: Int,
    val center: Float,
    val size: Int,
)

internal fun categoryKey(categoryId: String): String = "category-$categoryId"

internal fun categoryIdFromKey(key: Any?): String? =
    (key as? String)?.takeIf { it.startsWith("category-") }?.removePrefix("category-")

internal fun <T> List<T>.moved(fromIndex: Int, toIndex: Int): List<T> {
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

internal fun Budget.transactionItems(): List<TransactionListItem> =
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

internal fun newCategoryTitleResource(type: CategoryType): Int =
    when (type) {
        CategoryType.INCOME -> R.string.new_income
        CategoryType.EXPENSES -> R.string.new_category
        CategoryType.SAVINGS -> R.string.new_fund
        CategoryType.DEBT -> R.string.new_debt
    }

private fun defaultCurrencyCode(): String =
    runCatching { Currency.getInstance(Locale.getDefault()).currencyCode }.getOrDefault("USD")

internal fun currentMonthTitle(now: Date = Date()): String =
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
