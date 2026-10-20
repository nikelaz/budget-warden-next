package com.lazarovco.budgetwarden.android

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.android.data.GoogleDriveController
import com.lazarovco.budgetwarden.android.data.GoogleDriveUiState
import com.lazarovco.budgetwarden.android.data.locationDescription
import com.lazarovco.budgetwarden.core.BWCloudBudget
import com.lazarovco.budgetwarden.core.BWCloudShare
import com.lazarovco.budgetwarden.core.BWCloudShareRole
import kotlinx.coroutines.launch

/** The Google Drive part of the budget list. */
internal fun LazyListScope.googleDriveSection(
    drive: GoogleDriveUiState,
    onConnect: () -> Unit,
    onRefresh: () -> Unit,
    onOpen: (BWCloudBudget) -> Unit,
    onShare: (BWCloudBudget) -> Unit,
) {
    if (!drive.enabled) return
    item(key = "google-drive-header") {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Column(modifier = Modifier.weight(1f)) {
                Text(stringResource(R.string.google_drive), style = MaterialTheme.typography.titleSmall)
                Text(
                    text = drive.email ?: stringResource(R.string.google_drive_description),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (drive.signedIn) {
                if (drive.refreshing) {
                    CircularProgressIndicator(modifier = Modifier.padding(12.dp))
                } else {
                    TextButton(onClick = onRefresh) { Text(stringResource(R.string.refresh)) }
                }
            }
        }
    }
    drive.error?.let { error ->
        item(key = "google-drive-error") {
            Text(error, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error)
        }
    }
    if (!drive.signedIn) {
        item(key = "google-drive-connect") {
            Button(onClick = onConnect, enabled = !drive.signingIn, modifier = Modifier.fillMaxWidth()) {
                Text(stringResource(if (drive.signingIn) R.string.signing_in else R.string.connect_google_drive))
            }
        }
        return
    }
    if (drive.budgets.isEmpty()) {
        item(key = "google-drive-empty") {
            Text(
                stringResource(R.string.google_drive_empty),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
    items(drive.budgets, key = { "google-drive-${it.id}" }) { budget ->
        CloudBudgetRow(budget = budget, onOpen = { onOpen(budget) }, onShare = { onShare(budget) })
    }
}

@Composable
private fun CloudBudgetRow(budget: BWCloudBudget, onOpen: () -> Unit, onShare: () -> Unit) {
    val shape = RoundedCornerShape(8.dp)
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .clickable(onClick = onOpen),
        shape = shape,
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow),
    ) {
        Row(
            modifier = Modifier.padding(start = 12.dp, top = 10.dp, end = 4.dp, bottom = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(budget.title, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text(
                    budget.locationDescription,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            if (budget.canShare) {
                IconButton(onClick = onShare) {
                    Icon(painterResource(R.drawable.ic_share), contentDescription = stringResource(R.string.share))
                }
            }
        }
    }
}

/** The Google Drive account controls in Settings. */
@Composable
internal fun GoogleDriveSettings(
    drive: GoogleDriveUiState,
    cloudBudget: BWCloudBudget?,
    onConnect: () -> Unit,
    onSignOut: () -> Unit,
    onShare: (BWCloudBudget) -> Unit,
) {
    if (!drive.enabled) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.google_drive), style = MaterialTheme.typography.titleMedium)
        Text(
            stringResource(R.string.google_drive_sync_description),
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (drive.signedIn) {
            drive.email?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
            if (cloudBudget != null && cloudBudget.canShare) {
                Button(onClick = { onShare(cloudBudget) }) { Text(stringResource(R.string.share)) }
            }
            OutlinedButton(onClick = onSignOut) { Text(stringResource(R.string.sign_out_google_drive)) }
        } else {
            Button(onClick = onConnect, enabled = !drive.signingIn) {
                Text(stringResource(if (drive.signingIn) R.string.signing_in else R.string.connect_google_drive))
            }
        }
    }
}

/** Invites people to a Google Drive budget and manages who has access. */
@Composable
internal fun GoogleDriveShareDialog(
    controller: GoogleDriveController,
    budget: BWCloudBudget,
    onDismiss: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var email by remember { mutableStateOf("") }
    var canEdit by remember { mutableStateOf(true) }
    var message by remember { mutableStateOf("") }
    var shares by remember { mutableStateOf<List<BWCloudShare>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var sending by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun reload() {
        loading = true
        runCatching { controller.shares(budget) }
            .onSuccess { shares = it }
            .onFailure { error = it.message }
        loading = false
    }

    LaunchedEffect(budget.id) { reload() }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(stringResource(R.string.share_budget_title, budget.title)) },
        text = {
            Column(
                modifier = Modifier.verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (budget.canShare) {
                    OutlinedTextField(
                        value = email,
                        onValueChange = { email = it },
                        label = { Text(stringResource(R.string.share_email)) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Email),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                        listOf(true to R.string.share_can_edit, false to R.string.share_can_view)
                            .forEachIndexed { index, (value, label) ->
                                SegmentedButton(
                                    selected = canEdit == value,
                                    onClick = { canEdit = value },
                                    shape = SegmentedButtonDefaults.itemShape(index, 2),
                                ) { Text(stringResource(label)) }
                            }
                    }
                    OutlinedTextField(
                        value = message,
                        onValueChange = { message = it },
                        label = { Text(stringResource(R.string.share_message)) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    Text(
                        stringResource(R.string.share_explanation),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Button(
                        onClick = {
                            sending = true
                            scope.launch {
                                runCatching { controller.share(budget, email, canEdit, message) }
                                    .onSuccess {
                                        email = ""
                                        message = ""
                                        error = null
                                        reload()
                                    }
                                    .onFailure { error = it.message }
                                sending = false
                            }
                        },
                        enabled = email.contains('@') && !sending,
                    ) { Text(stringResource(R.string.share_send)) }
                }
                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                Text(stringResource(R.string.share_people), style = MaterialTheme.typography.titleSmall)
                if (loading) CircularProgressIndicator()
                shares.forEach { share ->
                    ShareRow(
                        share = share,
                        canRemove = budget.canShare && share.role != BWCloudShareRole.OWNER,
                        onRemove = {
                            scope.launch {
                                runCatching { controller.removeShare(budget, share) }
                                    .onFailure { error = it.message }
                                reload()
                            }
                        },
                    )
                }
            }
        },
        confirmButton = {
            TextButton(onClick = onDismiss) { Text(stringResource(R.string.done)) }
        },
    )
}

@Composable
private fun ShareRow(share: BWCloudShare, canRemove: Boolean, onRemove: () -> Unit) {
    val role = stringResource(
        when (share.role) {
            BWCloudShareRole.OWNER -> R.string.share_owner
            BWCloudShareRole.WRITER -> R.string.share_can_edit
            BWCloudShareRole.COMMENTER -> R.string.share_can_comment
            BWCloudShareRole.READER -> R.string.share_can_view
        },
    )
    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.weight(1f)) {
            Text(share.displayName ?: share.email ?: share.kind, style = MaterialTheme.typography.bodyMedium)
            Text(
                if (share.displayName != null && share.email != null) "${share.email} · $role" else role,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
        if (canRemove) {
            IconButton(onClick = onRemove) {
                Icon(painterResource(R.drawable.ic_delete), contentDescription = stringResource(R.string.share_remove))
            }
        }
    }
}
