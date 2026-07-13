package com.lazarovco.budgetwarden

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.domain.Budget
import java.util.Currency

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun SettingsScreen(
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
