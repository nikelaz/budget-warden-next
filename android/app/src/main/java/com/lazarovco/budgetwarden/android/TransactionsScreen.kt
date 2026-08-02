package com.lazarovco.budgetwarden.android

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.android.domain.Budget
import com.lazarovco.budgetwarden.android.domain.BudgetDates
import com.lazarovco.budgetwarden.android.domain.Money
import com.lazarovco.budgetwarden.android.domain.TransactionListItem
import com.lazarovco.budgetwarden.android.domain.title

@Composable
internal fun TransactionsScreen(
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
            Money.inputText(it.transaction.amount.value),
            Money.format(it.transaction.amount.value, currencyCode),
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
                Text(
                    Money.format(item.transaction.amount.value, currencyCode),
                    style = MaterialTheme.typography.bodyMedium,
                )
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
