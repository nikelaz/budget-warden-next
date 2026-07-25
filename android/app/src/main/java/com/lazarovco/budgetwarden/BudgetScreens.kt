package com.lazarovco.budgetwarden

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import com.lazarovco.budgetwarden.data.BudgetRepository
import com.lazarovco.budgetwarden.data.VaultType
import com.lazarovco.budgetwarden.domain.AmountMode
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.Category
import com.lazarovco.budgetwarden.domain.CategoryType
import com.lazarovco.budgetwarden.domain.Money
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun BudgetListScreen(
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
internal fun BudgetDetailScreen(
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
