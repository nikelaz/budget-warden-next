package com.lazarovco.budgetwarden

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.domain.Budget
import java.util.Currency

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsScreen(
    budget: Budget,
    currencyCode: String,
    modifier: Modifier = Modifier,
    onCurrencyChange: (String) -> Unit,
    onRenameBudget: (String) -> Unit,
    onDeleteBudget: () -> Unit,
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
        Text(stringResource(R.string.budget_title), style = MaterialTheme.typography.titleMedium)
        OutlinedTextField(
            value = title,
            onValueChange = { title = it },
            label = { Text(stringResource(R.string.name)) },
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            modifier = Modifier
                .fillMaxWidth()
                .onFocusChanged { focusState ->
                    if (titleHadFocus && !focusState.isFocused) {
                        val normalized = title.trim()
                        if (normalized.isNotEmpty() && normalized != budget.title) {
                            onRenameBudget(normalized)
                        }
                    }
                    titleHadFocus = focusState.isFocused
                },
        )

        Text(stringResource(R.string.currency), style = MaterialTheme.typography.titleMedium)
        ExposedDropdownMenuBox(expanded = expanded, onExpandedChange = { expanded = it }) {
            OutlinedTextField(
                value = currencyCode,
                onValueChange = {},
                readOnly = true,
                label = { Text(stringResource(R.string.currency)) },
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded) },
                modifier = Modifier
                    .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                    .fillMaxWidth(),
            )
            ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
                currencies.forEach { code ->
                    DropdownMenuItem(
                        text = { Text(code) },
                        onClick = { expanded = false; onCurrencyChange(code) },
                    )
                }
            }
        }

        Text(stringResource(R.string.actions), style = MaterialTheme.typography.titleMedium)
        OutlinedButton(onClick = onDeleteBudget, modifier = Modifier.fillMaxWidth()) {
            Text(stringResource(R.string.delete_budget_action))
        }
    }
}
