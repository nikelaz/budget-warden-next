package com.lazarovco.budgetwarden

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuAnchorType
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import com.lazarovco.budgetwarden.domain.Budget
import com.lazarovco.budgetwarden.domain.BudgetDates
import com.lazarovco.budgetwarden.domain.Category
import com.lazarovco.budgetwarden.domain.CategoryType
import com.lazarovco.budgetwarden.domain.Money
import com.lazarovco.budgetwarden.domain.TemplateSelection
import com.lazarovco.budgetwarden.domain.title
import com.lazarovco.budgetwarden.core.BWDate
import java.util.UUID

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CreateBudgetDialog(
    budgets: List<Budget>,
    onDismiss: () -> Unit,
    onCreate: (String, TemplateSelection, Budget?) -> Unit,
) {
    var title by rememberSaveable { mutableStateOf(currentMonthTitle()) }
    var template by rememberSaveable { mutableStateOf(TemplateSelection.BASIC) }
    var previousBudgetId by rememberSaveable { mutableStateOf(budgets.firstOrNull()?.id) }
    var templateExpanded by rememberSaveable { mutableStateOf(false) }
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
                            .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
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
                    if (titleIsValid) onCreate(title, template, selectedPreviousBudget)
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
internal fun CategoryDialog(
    editor: CategoryEditor,
    onDismiss: () -> Unit,
    onSave: (String, String, CategoryType) -> Unit,
    onDelete: () -> Unit,
) {
    val initial = (editor as? CategoryEditor.Edit)?.category
    val creation = editor as? CategoryEditor.Create
    var title by rememberSaveable(editor.id) { mutableStateOf(initial?.title.orEmpty()) }
    var amount by rememberSaveable(editor.id) {
        mutableStateOf(Money.inputText(initial?.amountPlanned?.value ?: 0L))
    }
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
internal fun TransactionDialog(
    editor: TransactionEditor,
    categories: List<Category>,
    onDismiss: () -> Unit,
    onSave: (UUID, String, String, String, String) -> Unit,
    onDelete: () -> Unit,
) {
    val item = (editor as? TransactionEditor.Edit)?.item
    var categoryId by rememberSaveable(editor.id) {
        mutableStateOf(
            (item?.category?.id
                ?: (editor as? TransactionEditor.Create)?.initialCategoryId
                ?: categories.firstOrNull()?.id)?.toString().orEmpty(),
        )
    }
    var title by rememberSaveable(editor.id) { mutableStateOf(item?.transaction?.title.orEmpty()) }
    var description by rememberSaveable(editor.id) { mutableStateOf(item?.transaction?.description.orEmpty()) }
    var dateText by rememberSaveable(editor.id) {
        mutableStateOf(BudgetDates.inputText(item?.transaction?.date ?: BWDate.now()))
    }
    var amount by rememberSaveable(editor.id) {
        mutableStateOf(Money.inputText(item?.transaction?.amount?.value ?: 0L))
    }
    var categoryExpanded by remember { mutableStateOf(false) }
    var detailsExpanded by rememberSaveable(editor.id) { mutableStateOf(false) }
    var datePickerVisible by remember { mutableStateOf(false) }
    var submitted by rememberSaveable(editor.id) { mutableStateOf(false) }
    val titleIsValid = title.isNotBlank()
    val amountValue = Money.parse(amount)
    val amountIsValid = amountValue != null && amountValue > 0L
    val categoryIsValid = categories.any { it.id.toString() == categoryId }
    val dateIsValid = BudgetDates.parseInput(dateText) != null
    val formIsValid = titleIsValid && amountIsValid && categoryIsValid && dateIsValid
    val showTitleError = submitted && !titleIsValid
    val showAmountError = submitted && !amountIsValid
    val showCategoryError = submitted && !categoryIsValid
    val showDateError = submitted && !dateIsValid

    if (datePickerVisible) {
        val datePickerState = rememberDatePickerState(
            initialSelectedDateMillis = BudgetDates.parseInput(dateText)
                ?.let(BudgetDates::toEpochMilliseconds),
        )
        DatePickerDialog(
            onDismissRequest = { datePickerVisible = false },
            confirmButton = {
                TextButton(onClick = {
                    datePickerState.selectedDateMillis?.let {
                        dateText = BudgetDates.inputText(BudgetDates.fromEpochMilliseconds(it))
                    }
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
                        value = categories.firstOrNull { it.id.toString() == categoryId }?.title.orEmpty(),
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
                        modifier = Modifier
                            .menuAnchor(ExposedDropdownMenuAnchorType.PrimaryNotEditable)
                            .fillMaxWidth(),
                    )
                    ExposedDropdownMenu(expanded = categoryExpanded, onDismissRequest = { categoryExpanded = false }) {
                        categories.forEach { category ->
                            DropdownMenuItem(text = { Text(category.title) }, onClick = {
                                categoryId = category.id.toString()
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
                if (formIsValid) onSave(UUID.fromString(categoryId), title, description, dateText, amount)
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
