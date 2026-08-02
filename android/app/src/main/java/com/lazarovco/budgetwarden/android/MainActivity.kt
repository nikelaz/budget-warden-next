package com.lazarovco.budgetwarden.android

import android.net.Uri
import android.os.Bundle
import android.content.Context
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
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
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.ToggleFloatingActionButton
import androidx.compose.material3.ToggleFloatingActionButtonDefaults.animateIcon
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.adaptive.navigationsuite.NavigationSuiteScaffold
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.core.BWCategory
import com.lazarovco.budgetwarden.core.BWMoneyAmount
import com.lazarovco.budgetwarden.core.BWTransaction
import com.lazarovco.budgetwarden.core.createCategory
import com.lazarovco.budgetwarden.core.createTransaction
import com.lazarovco.budgetwarden.core.deleteCategory
import com.lazarovco.budgetwarden.core.deleteTransaction
import com.lazarovco.budgetwarden.core.encodeBudget
import com.lazarovco.budgetwarden.core.moveTransaction
import com.lazarovco.budgetwarden.core.newTransaction
import com.lazarovco.budgetwarden.core.updateCategory
import com.lazarovco.budgetwarden.core.updateBudgetTitle
import com.lazarovco.budgetwarden.core.updateTransaction
import com.lazarovco.budgetwarden.android.data.BudgetRepository
import com.lazarovco.budgetwarden.android.data.StoredBudget
import com.lazarovco.budgetwarden.android.domain.Budget
import com.lazarovco.budgetwarden.android.domain.BudgetDates
import com.lazarovco.budgetwarden.android.domain.Category
import com.lazarovco.budgetwarden.android.domain.CategoryType
import com.lazarovco.budgetwarden.android.domain.Money
import com.lazarovco.budgetwarden.android.domain.TemplateSelection
import com.lazarovco.budgetwarden.android.domain.TransactionListItem
import com.lazarovco.budgetwarden.android.domain.rawValue
import com.lazarovco.budgetwarden.android.ui.theme.BudgetWardenAndroidTheme
import java.text.SimpleDateFormat
import java.util.Currency
import java.util.Date
import java.util.Locale
import java.util.UUID

private const val BUDGET_MIME_TYPE = "application/vnd.lazarovco.budgetwarden.budget"
private const val JSON_MIME_TYPE = "application/json"

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
    val context = LocalContext.current
    val resources = LocalResources.current
    val repository = remember { BudgetRepository(context) }
    val sessionViewModel: BudgetSessionViewModel = viewModel(
        factory = remember(repository) { BudgetSessionViewModel.Factory(repository) },
    )
    val sessionState by sessionViewModel.state.collectAsStateWithLifecycle()
    val preferences = remember {
        context.getSharedPreferences(BudgetWardenApplication.PREFERENCES_NAME, Context.MODE_PRIVATE)
    }
    val snackbarHostState = remember { SnackbarHostState() }

    val storedBudgets = sessionState.storedBudgets
    val currentBudget = sessionState.currentBudget
    var selectedTab by rememberSaveable { mutableStateOf(AppDestination.BUDGET) }
    var transactionSearchActive by rememberSaveable { mutableStateOf(false) }
    var transactionSearchText by rememberSaveable { mutableStateOf("") }
    var currencyCode by rememberSaveable {
        mutableStateOf(preferences.getString("currency_code", null) ?: defaultCurrencyCode())
    }
    var createBudgetOpen by rememberSaveable { mutableStateOf(false) }
    var pendingCreationTitle by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingCreationTemplate by rememberSaveable { mutableStateOf<String?>(null) }
    var pendingPreviousBudgetJson by rememberSaveable { mutableStateOf<String?>(null) }
    var categoryEditor by remember { mutableStateOf<CategoryEditor?>(null) }
    var transactionEditor by remember { mutableStateOf<TransactionEditor?>(null) }
    var categoryPendingDeletion by remember { mutableStateOf<Category?>(null) }
    var transactionPendingDeletion by remember { mutableStateOf<TransactionListItem?>(null) }
    var budgetPendingDeletion by remember { mutableStateOf<StoredBudget?>(null) }

    fun openBudget(uri: Uri) {
        sessionViewModel.openBudget(uri)
    }

    fun mutateBudget(operation: (Budget) -> Budget) {
        sessionViewModel.mutateBudget(operation)
    }

    LaunchedEffect(sessionViewModel, resources) {
        sessionViewModel.errors.collect { error ->
            snackbarHostState.showSnackbar(
                error.cause.message ?: resources.getString(error.kind.messageResource),
            )
        }
    }

    val openDocument = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        uri?.let(::openBudget)
    }
    val createDocument = rememberLauncherForActivityResult(
        ActivityResultContracts.CreateDocument(BUDGET_MIME_TYPE),
    ) { uri ->
        val title = pendingCreationTitle
        val template = pendingCreationTemplate?.let(TemplateSelection::valueOf)
        val previousBudgetJson = pendingPreviousBudgetJson
        pendingCreationTitle = null
        pendingCreationTemplate = null
        pendingPreviousBudgetJson = null
        if (uri != null && title != null && template != null) {
            sessionViewModel.createBudget(
                uri = uri,
                title = title,
                template = template,
                previousBudgetJson = previousBudgetJson,
            )
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) },
        contentWindowInsets = WindowInsets(0, 0, 0, 0),
    ) { outerPadding ->
        val budget = currentBudget
        if (budget == null) {
            BudgetListScreen(
                storedBudgets = storedBudgets,
                modifier = Modifier.padding(outerPadding),
                onCreateBudget = { createBudgetOpen = true },
                onOpenBudget = {
                    openDocument.launch(arrayOf(BUDGET_MIME_TYPE, JSON_MIME_TYPE, "*/*"))
                },
                onSelectBudget = { openBudget(it.uri) },
                onDeleteBudget = { budgetPendingDeletion = it },
            )
        } else {
            NavigationSuiteScaffold(
                navigationSuiteItems = {
                    AppDestination.entries.forEach { destination ->
                        item(
                            icon = {
                                Icon(
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
                            budget = budget,
                            storedBudgets = storedBudgets,
                            searchAvailable = selectedTab == AppDestination.TRANSACTIONS,
                            searchActive = transactionSearchActive,
                            searchText = transactionSearchText,
                            onSearchActiveChange = { active ->
                                transactionSearchActive = active
                                if (!active) transactionSearchText = ""
                            },
                            onSearchTextChange = { transactionSearchText = it },
                            onAllBudgets = sessionViewModel::closeBudget,
                            onCreateBudget = { createBudgetOpen = true },
                            onSelectBudget = { openBudget(it.uri) },
                        )
                    },
                    floatingActionButton = {
                        WorkspaceFab(
                            tab = selectedTab,
                            canCreateTransaction = budget.categories.isNotEmpty(),
                            onCreateBudget = { createBudgetOpen = true },
                            onCreateCategory = {
                                categoryEditor = CategoryEditor.Create(
                                    categoryType = CategoryType.EXPENSES,
                                    typeSelectionEnabled = true,
                                )
                            },
                            onCreateTransaction = {
                                transactionEditor = TransactionEditor.Create(
                                    budget.orderedCategories(null).firstOrNull()?.id,
                                )
                            },
                        )
                    },
                ) { innerPadding ->
                    when (selectedTab) {
                        AppDestination.BUDGET -> BudgetDetailScreen(
                            budget = budget,
                            currencyCode = currencyCode,
                            modifier = Modifier.padding(innerPadding),
                            onCreateCategory = { categoryEditor = CategoryEditor.Create(it) },
                            onEditCategory = { categoryEditor = CategoryEditor.Edit(it) },
                            onDeleteCategory = { categoryPendingDeletion = it },
                            onReorderCategory = { type, ordered ->
                                mutateBudget { reorderCategories(it, type, ordered) }
                            },
                        )

                        AppDestination.REPORTING -> ReportingScreen(
                            budget = budget,
                            currencyCode = currencyCode,
                            modifier = Modifier.padding(innerPadding),
                        )

                        AppDestination.TRANSACTIONS -> TransactionsScreen(
                            budget = budget,
                            currencyCode = currencyCode,
                            searchText = transactionSearchText,
                            modifier = Modifier.padding(innerPadding),
                            onEditTransaction = { transactionEditor = TransactionEditor.Edit(it) },
                            onDeleteTransaction = { transactionPendingDeletion = it },
                        )

                        AppDestination.SETTINGS -> SettingsScreen(
                            budget = budget,
                            currencyCode = currencyCode,
                            modifier = Modifier.padding(innerPadding),
                            onCurrencyChange = {
                                currencyCode = it
                                preferences.edit().putString("currency_code", it).apply()
                            },
                            onRenameBudget = { title ->
                                mutateBudget { updateBudgetTitle(it, title.trim()) }
                            },
                            onDeleteBudget = {
                                budgetPendingDeletion = StoredBudget(
                                    budget = budget,
                                    uri = Uri.parse(checkNotNull(budget.url)),
                                    displayName = budget.title,
                                )
                            },
                        )
                    }
                }
            }
        }
    }

    if (createBudgetOpen) {
        CreateBudgetDialog(
            budgets = storedBudgets.map { it.budget },
            onDismiss = { createBudgetOpen = false },
            onCreate = { title, template, previous ->
                createBudgetOpen = false
                pendingCreationTitle = title
                pendingCreationTemplate = template.name
                pendingPreviousBudgetJson = previous?.let(::encodeBudget)
                createDocument.launch(repository.normalizedFileName(title))
            },
        )
    }

    categoryEditor?.let { editor ->
        CategoryDialog(
            editor = editor,
            onDismiss = { categoryEditor = null },
            onSave = { title, amount, type ->
                val cents = Money.parse(amount) ?: return@CategoryDialog
                categoryEditor = null
                mutateBudget { budget ->
                    when (editor) {
                        is CategoryEditor.Create -> {
                            val ordinal = budget.categories.count { it.categoryType == type }
                            createCategory(
                                budget = budget,
                                category = BWCategory(
                                    id = UUID.randomUUID(),
                                    ordinal = ordinal,
                                    title = title.trim(),
                                    amountPlanned = BWMoneyAmount(cents),
                                    amountActual = BWMoneyAmount(0),
                                    amountAccumulated = BWMoneyAmount(0),
                                    categoryType = type,
                                    transactions = emptyList(),
                                ),
                            )
                        }
                        is CategoryEditor.Edit -> updateCategory(
                            budget = budget,
                            category = editor.category.copy(
                                title = title.trim(),
                                amountPlanned = BWMoneyAmount(cents),
                                categoryType = type,
                            ),
                        )
                    }
                }
            },
            onDelete = {
                if (editor is CategoryEditor.Edit) {
                    categoryEditor = null
                    categoryPendingDeletion = editor.category
                }
            },
        )
    }

    categoryPendingDeletion?.let { category ->
        AlertDialog(
            onDismissRequest = { categoryPendingDeletion = null },
            title = { Text(stringResource(R.string.delete_category_title)) },
            text = { Text(stringResource(R.string.delete_category_message, category.title)) },
            confirmButton = {
                TextButton(onClick = {
                    categoryPendingDeletion = null
                    mutateBudget { deleteCategory(it, category.id) }
                }) { Text(stringResource(R.string.delete_category)) }
            },
            dismissButton = {
                TextButton(onClick = { categoryPendingDeletion = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    transactionEditor?.let { editor ->
        val budget = currentBudget
        if (budget != null) {
            TransactionDialog(
                editor = editor,
                categories = budget.orderedCategories(null),
                onDismiss = { transactionEditor = null },
                onSave = { categoryId, title, description, dateText, amountText ->
                    val amount = Money.parse(amountText) ?: return@TransactionDialog
                    val date = BudgetDates.parseInput(dateText) ?: return@TransactionDialog
                    transactionEditor = null
                    mutateBudget { startingBudget ->
                        when (editor) {
                            is TransactionEditor.Create -> createTransaction(
                                budget = startingBudget,
                                categoryId = categoryId,
                                transaction = newTransaction(
                                    title = title.trim(),
                                    description = description.trim(),
                                    date = date,
                                    amount = BWMoneyAmount(amount),
                                ),
                            )
                            is TransactionEditor.Edit -> {
                                val transaction = BWTransaction(
                                    id = editor.item.transaction.id,
                                    title = title.trim(),
                                    description = description.trim(),
                                    date = date,
                                    amount = BWMoneyAmount(amount),
                                )
                                var updated = updateTransaction(
                                    budget = startingBudget,
                                    categoryId = editor.item.category.id,
                                    transaction = transaction,
                                )
                                if (editor.item.category.id != categoryId) {
                                    updated = moveTransaction(
                                        budget = updated,
                                        originCategoryId = editor.item.category.id,
                                        targetCategoryId = categoryId,
                                        transactionId = transaction.id,
                                    )
                                }
                                updated
                            }
                        }
                    }
                },
                onDelete = {
                    if (editor is TransactionEditor.Edit) {
                        transactionEditor = null
                        transactionPendingDeletion = editor.item
                    }
                },
            )
        }
    }

    transactionPendingDeletion?.let { item ->
        AlertDialog(
            onDismissRequest = { transactionPendingDeletion = null },
            title = { Text(stringResource(R.string.delete_transaction_title)) },
            text = { Text(stringResource(R.string.delete_transaction_message, item.transaction.title)) },
            confirmButton = {
                TextButton(onClick = {
                    transactionPendingDeletion = null
                    mutateBudget { deleteTransaction(it, item.category.id, item.transaction.id) }
                }) { Text(stringResource(R.string.delete_transaction)) }
            },
            dismissButton = {
                TextButton(onClick = { transactionPendingDeletion = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }

    budgetPendingDeletion?.let { stored ->
        AlertDialog(
            onDismissRequest = { budgetPendingDeletion = null },
            title = { Text(stringResource(R.string.delete_budget_title)) },
            text = { Text(stringResource(R.string.delete_budget_message, stored.budget.title)) },
            confirmButton = {
                TextButton(onClick = {
                    budgetPendingDeletion = null
                    sessionViewModel.deleteBudget(stored)
                }) { Text(stringResource(R.string.delete_budget)) }
            },
            dismissButton = {
                TextButton(onClick = { budgetPendingDeletion = null }) {
                    Text(stringResource(R.string.cancel))
                }
            },
        )
    }
}

private fun reorderCategories(
    budget: Budget,
    type: CategoryType,
    orderedCategories: List<Category>,
): Budget {
    var updated = budget
    orderedCategories.map(Category::id).forEachIndexed { targetOrdinal, categoryId ->
        val ordered = updated.orderedCategories(type)
        if (ordered.getOrNull(targetOrdinal)?.id != categoryId) {
            val category = ordered.first { it.id == categoryId }.copy(ordinal = targetOrdinal)
            updated = updateCategory(updated, category)
        }
    }
    return updated
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
    storedBudgets: List<StoredBudget>,
    searchAvailable: Boolean,
    searchActive: Boolean,
    searchText: String,
    onSearchActiveChange: (Boolean) -> Unit,
    onSearchTextChange: (String) -> Unit,
    onAllBudgets: () -> Unit,
    onCreateBudget: () -> Unit,
    onSelectBudget: (StoredBudget) -> Unit,
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
            } else {
                Box {
                    TextButton(onClick = { expanded = true }) {
                        Text(budget.title, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded)
                    }
                    DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                        storedBudgets.forEach { item ->
                            DropdownMenuItem(
                                text = { Text(item.budget.title) },
                                leadingIcon = {
                                    Icon(painterResource(R.drawable.ic_wallet), contentDescription = null)
                                },
                                onClick = { expanded = false; onSelectBudget(item) },
                            )
                        }
                        DropdownMenuItem(
                            text = { Text(stringResource(R.string.new_budget)) },
                            leadingIcon = {
                                Icon(painterResource(R.drawable.ic_add), contentDescription = null)
                            },
                            onClick = { expanded = false; onCreateBudget() },
                        )
                    }
                }
            }
        },
        actions = {
            when {
                searchActive && searchText.isNotEmpty() -> IconButton(onClick = { onSearchTextChange("") }) {
                    Icon(
                        painterResource(R.drawable.ic_close),
                        contentDescription = stringResource(R.string.clear_search),
                    )
                }
                searchAvailable && !searchActive -> IconButton(onClick = { onSearchActiveChange(true) }) {
                    Icon(
                        painterResource(R.drawable.ic_search),
                        contentDescription = stringResource(R.string.search_transactions),
                    )
                }
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
                        painter = painterResource(
                            if (checkedProgress > 0.5f) R.drawable.ic_close else R.drawable.ic_add,
                        ),
                        contentDescription = stringResource(
                            if (expanded) R.string.close_add_menu else R.string.add,
                        ),
                        modifier = Modifier.animateIcon(checkedProgress = { checkedProgress }),
                    )
                }
            },
        ) {
            FloatingActionButtonMenuItem(
                text = { Text(stringResource(R.string.category)) },
                icon = { Icon(painterResource(R.drawable.ic_list), contentDescription = null) },
                onClick = { expanded = false; onCreateCategory() },
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
                contentColor = if (canCreateTransaction) {
                    MaterialTheme.colorScheme.onPrimaryContainer
                } else {
                    MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                },
            )
            FloatingActionButtonMenuItem(
                text = { Text(stringResource(R.string.budget)) },
                icon = { Icon(painterResource(R.drawable.ic_wallet), contentDescription = null) },
                onClick = { expanded = false; onCreateBudget() },
            )
        }
        AppDestination.TRANSACTIONS -> FloatingActionButton(onClick = onCreateTransaction) {
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
        modifier = modifier.fillMaxSize().padding(32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(title, style = MaterialTheme.typography.titleLarge)
        Spacer(Modifier.height(8.dp))
        Text(message, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
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
    data class Create(val initialCategoryId: UUID?) : TransactionEditor("create-${initialCategoryId ?: ""}")
    data class Edit(val item: TransactionListItem) : TransactionEditor("edit-${item.transaction.id}")
}

internal data class ReorderItemInfo(
    val categoryId: UUID,
    val index: Int,
    val center: Float,
    val size: Int,
)

internal fun categoryKey(categoryId: UUID): String = "category-$categoryId"

internal fun categoryIdFromKey(key: Any?): UUID? =
    (key as? String)
        ?.takeIf { it.startsWith("category-") }
        ?.removePrefix("category-")
        ?.let(UUID::fromString)

internal fun <T> List<T>.moved(fromIndex: Int, toIndex: Int): List<T> {
    if (fromIndex == toIndex || fromIndex !in indices || toIndex !in indices) return this
    return toMutableList().apply { add(toIndex, removeAt(fromIndex)) }
}

internal fun Budget.transactionItems(): List<TransactionListItem> =
    categories.flatMap { category ->
        category.transactions.map { TransactionListItem(category, it) }
    }.sortedWith(
        compareByDescending<TransactionListItem> { it.transaction.date.year }
            .thenByDescending { it.transaction.date.month }
            .thenByDescending { it.transaction.date.day }
            .thenBy { it.transaction.title.lowercase() },
    )

internal fun newCategoryTitleResource(type: CategoryType): Int = when (type) {
    CategoryType.INCOME -> R.string.new_income
    CategoryType.EXPENSES -> R.string.new_category
    CategoryType.SAVINGS -> R.string.new_fund
    CategoryType.DEBT -> R.string.new_debt
}

private fun defaultCurrencyCode(): String =
    runCatching { Currency.getInstance(Locale.getDefault()).currencyCode }.getOrDefault("USD")

internal fun currentMonthTitle(now: Date = Date()): String =
    SimpleDateFormat("LLLL yyyy", Locale.getDefault()).format(now)

private val BudgetSessionErrorKind.messageResource: Int
    get() = when (this) {
        BudgetSessionErrorKind.LOAD_RECENTS -> R.string.error_load_recent_budgets
        BudgetSessionErrorKind.OPEN -> R.string.error_open_budget
        BudgetSessionErrorKind.CREATE -> R.string.error_create_budget
        BudgetSessionErrorKind.SAVE -> R.string.error_save_budget
        BudgetSessionErrorKind.DELETE -> R.string.error_delete_budget
    }

@Preview(showBackground = true)
@Composable
fun BudgetWardenPreview() {
    BudgetWardenAndroidTheme {
        BudgetListScreen(
            storedBudgets = emptyList(),
            onCreateBudget = {},
            onOpenBudget = {},
            onSelectBudget = {},
            onDeleteBudget = {},
        )
    }
}
