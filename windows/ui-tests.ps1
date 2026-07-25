param(
    [Parameter(Mandatory)]
    [int]$AppPid,
    [string]$BudgetPath = (Join-Path $PSScriptRoot 'test-artifacts\ui-automation.budget')
)

$ErrorActionPreference = 'Stop'
$pass = 0
$fail = 0
$results = @()
$artifactRoot = Join-Path $PSScriptRoot 'test-artifacts'
$screenshots = Join-Path $artifactRoot 'screenshots'
New-Item -ItemType Directory -Force -Path $screenshots | Out-Null
$BudgetPath = [System.IO.Path]::GetFullPath($BudgetPath)

function Test-UI {
    param([string]$Name, [scriptblock]$Script)
    try {
        & $Script
        $script:pass++
        $script:results += @{ name = $Name; status = 'PASS' }
    } catch {
        $script:fail++
        $script:results += @{ name = $Name; status = 'FAIL'; detail = $_.Exception.Message }
    }
}

function Invoke-Checked {
    param([scriptblock]$Command, [string]$Failure)
    & $Command | Out-Null
    if ($LASTEXITCODE -ne 0) { throw $Failure }
}

function Search-UI([string]$Text) {
    $json = winapp ui search $Text -a $AppPid --json 2>$null
    if (-not $json) { throw "UI search failed for '$Text'." }
    return $json | ConvertFrom-Json
}

if (-not (Get-Process -Id $AppPid -ErrorAction SilentlyContinue)) {
    throw "No running process has PID $AppPid."
}

$smokeProject = Join-Path $PSScriptRoot 'Tests\BudgetWarden.CoreSmoke\BudgetWarden.CoreSmoke.csproj'
dotnet run --project $smokeProject -- --output $BudgetPath
if ($LASTEXITCODE -ne 0) { throw 'The C# to Rust core smoke test failed.' }

$closeBudget = Search-UI 'CloseBudgetButton'
if ($closeBudget.matchCount -gt 0) {
    Invoke-Checked { winapp ui invoke CloseBudgetButton -a $AppPid } 'Could not close the current budget.'
}
Invoke-Checked { winapp ui wait-for WelcomeOpenBudgetButton -a $AppPid -t 5000 } 'The welcome view did not appear.'
winapp ui screenshot -a $AppPid -o (Join-Path $screenshots '01-welcome.png') 2>$null | Out-Null

Invoke-Checked { winapp ui invoke WelcomeOpenBudgetButton -a $AppPid } 'Could not invoke the Open budget button.'
Start-Sleep -Milliseconds 700
$pickerWindows = winapp ui list-windows -a $AppPid --json 2>$null | ConvertFrom-Json
$picker = $pickerWindows | Where-Object { $_.title -match 'Open' -or $_.className -match 'PickerHost|#32770' } | Select-Object -First 1
if (-not $picker) { throw 'The Windows file picker did not appear.' }
$fileNameMatches = winapp ui search 'File name:' -w $picker.hwnd --json 2>$null | ConvertFrom-Json
$fileNameEdit = $fileNameMatches.matches | Where-Object type -eq 'Edit' | Select-Object -First 1
if (-not $fileNameEdit) { throw 'The picker file-name edit control was not found.' }
Invoke-Checked { winapp ui set-value $fileNameEdit.selector $BudgetPath -w $picker.hwnd } 'Could not set the picker file name.'
$openMatches = winapp ui search Open -w $picker.hwnd --json 2>$null | ConvertFrom-Json
$openButton = $openMatches.matches | Where-Object { $_.type -eq 'Button' -and $_.automationId -eq '1' } | Select-Object -First 1
if (-not $openButton) { throw 'The picker Open button was not found.' }
Invoke-Checked { winapp ui invoke $openButton.selector -w $picker.hwnd } 'Could not confirm the Windows file picker.'
Invoke-Checked { winapp ui wait-for ShellNavigation -a $AppPid -t 5000 } 'The budget shell did not appear.'

Test-UI 'Monthly template categories render' {
    $salary = Search-UI 'Salary'
    if ($salary.matchCount -lt 1) { throw 'Salary category was not rendered.' }
}

Test-UI 'Create category through Rust core' {
    Invoke-Checked { winapp ui invoke NewCategoryButton -a $AppPid } 'New category dialog did not open.'
    Invoke-Checked { winapp ui set-value CategoryTitleBox 'UI Automation Category' -a $AppPid } 'Could not set category title.'
    Invoke-Checked { winapp ui set-value CategoryPlannedAmountBox '321.45' -a $AppPid } 'Could not set planned amount.'
    Invoke-Checked { winapp ui wait-for PrimaryButton -a $AppPid -p IsEnabled --value True -t 3000 } 'Category Save button was not enabled.'
    Invoke-Checked { winapp ui invoke PrimaryButton -a $AppPid } 'Could not save the category.'
    Invoke-Checked { winapp ui wait-for PrimaryButton -a $AppPid --gone -t 5000 } 'Category dialog did not close.'
    $category = Search-UI 'UI Automation Category'
    if ($category.matchCount -lt 1) { throw 'Created category did not appear.' }
}

Test-UI 'Create transaction through Rust core' {
    Invoke-Checked { winapp ui invoke NewTransactionButton -a $AppPid } 'New transaction dialog did not open.'
    Invoke-Checked { winapp ui set-value TransactionTitleBox 'UI Automation Paycheck' -a $AppPid } 'Could not set transaction title.'
    Invoke-Checked { winapp ui set-value TransactionAmountBox '10.25' -a $AppPid } 'Could not set transaction amount.'
    Invoke-Checked { winapp ui set-value TransactionDescriptionBox 'WinApp UI smoke test' -a $AppPid } 'Could not set transaction description.'
    Invoke-Checked { winapp ui wait-for PrimaryButton -a $AppPid -p IsEnabled --value True -t 3000 } 'Transaction Save button was not enabled.'
    Invoke-Checked { winapp ui invoke PrimaryButton -a $AppPid } 'Could not save the transaction.'
    Invoke-Checked { winapp ui wait-for PrimaryButton -a $AppPid --gone -t 5000 } 'Transaction dialog did not close.'
}

Test-UI 'Transactions navigation and search' {
    Invoke-Checked { winapp ui invoke NavTransactions -a $AppPid } 'Could not navigate to Transactions.'
    Invoke-Checked { winapp ui wait-for TransactionSearchBox -a $AppPid -t 3000 } 'Transactions page did not load.'
    $transaction = Search-UI 'UI Automation Paycheck'
    if ($transaction.matchCount -lt 1) { throw 'Created transaction did not appear.' }
    Invoke-Checked { winapp ui send-keys 'Automation Paycheck' --target TransactionSearchBox -a $AppPid --via send-input } 'Could not enter a transaction search.'
    $filtered = Search-UI 'UI Automation Paycheck'
    if ($filtered.matchCount -lt 1) { throw 'Transaction search removed the expected result.' }
}
winapp ui screenshot -a $AppPid -o (Join-Path $screenshots '02-transactions.png') 2>$null | Out-Null

Test-UI 'Reporting navigation' {
    Invoke-Checked { winapp ui invoke NavReporting -a $AppPid } 'Could not navigate to Reporting.'
    Invoke-Checked { winapp ui wait-for ReportingList -a $AppPid -t 3000 } 'Reporting page did not load.'
}
winapp ui screenshot -a $AppPid -o (Join-Path $screenshots '03-reporting.png') 2>$null | Out-Null

Test-UI 'Settings navigation' {
    Invoke-Checked { winapp ui invoke SettingsItem -a $AppPid } 'Could not navigate to Settings.'
    Invoke-Checked { winapp ui wait-for CurrencyComboBox -a $AppPid -t 3000 } 'Settings page did not load.'
    Invoke-Checked { winapp ui wait-for CurrencyComboBox -a $AppPid --value 'USD' --contains -t 3000 } 'The default currency was not USD.'
}
winapp ui screenshot -a $AppPid -o (Join-Path $screenshots '04-settings.png') 2>$null | Out-Null

Test-UI 'Mutations persist in portable budget JSON' {
    $document = Get-Content $BudgetPath -Raw | ConvertFrom-Json
    $category = $document.categories | Where-Object title -eq 'UI Automation Category'
    if (-not $category -or $category.amount_planned -ne 32145) { throw 'Category mutation was not persisted correctly.' }
    $transaction = $document.categories.transactions | Where-Object title -eq 'UI Automation Paycheck'
    if (-not $transaction -or $transaction.amount -ne 1025) { throw 'Transaction mutation was not persisted correctly.' }
}

Test-UI 'Interactive controls expose automation IDs' {
    $inspection = winapp ui inspect -a $AppPid --interactive --json 2>$null | ConvertFrom-Json
    $controls = @($inspection.windows.elements | Where-Object {
        $_.type -match 'Button|TextBox|ComboBox|CheckBox|ToggleSwitch|Edit' -and
        $_.name -notmatch 'Minimize|Maximize|Close|System' -and
        $_.className -notmatch 'PickerHost|#32770|CabinetWClass'
    })
    $missing = @($controls | Where-Object { -not $_.automationId })
    if ($missing.Count -gt 0) {
        throw "Missing automation IDs: $(($missing | ForEach-Object { "$($_.type) '$($_.name)'" }) -join ', ')"
    }
}

$results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $artifactRoot 'test-results.json')
Write-Host "Passed: $pass | Failed: $fail"
$results | Where-Object status -eq 'FAIL' | ForEach-Object {
    Write-Host "  FAIL: $($_.name) - $($_.detail)" -ForegroundColor Red
}
if ($fail -gt 0) { exit 1 }
