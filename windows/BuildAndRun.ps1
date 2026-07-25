param(
    [switch]$SkipRun,
    [switch]$Detach,
    [ValidateSet('Debug', 'Release')]
    [string]$Configuration = 'Debug'
)

$ErrorActionPreference = 'Stop'
$project = Join-Path $PSScriptRoot 'BudgetWarden.Windows.csproj'
$repositoryRoot = Split-Path $PSScriptRoot -Parent
$coreManifest = Get-Content (Join-Path $repositoryRoot 'core\Cargo.toml') -Raw
$coreVersion = [regex]::Match($coreManifest, '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
$corePackage = Join-Path $repositoryRoot "core\dist\csharp\packages\bw_core.$coreVersion.nupkg"

if (-not (Test-Path $corePackage)) {
    throw "The generated Rust core package is missing. Run .\BuildCore.ps1 first."
}
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw '.NET SDK 10 is required.'
}

$devMode = Get-ItemPropertyValue `
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' `
    'AllowDevelopmentWithoutDevLicense' `
    -ErrorAction SilentlyContinue
if ($devMode -ne 1) {
    throw 'Windows Developer Mode must be enabled.'
}

dotnet build $project -p:Platform=x64 -p:Configuration=$Configuration
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($SkipRun) {
    Write-Host 'Build succeeded.' -ForegroundColor Green
    exit 0
}
if (-not (Get-Command winapp -ErrorAction SilentlyContinue)) {
    throw 'WinApp CLI is required to launch this packaged WinUI app.'
}

$configurationRoot = Join-Path $PSScriptRoot "bin\x64\$Configuration"
$tfmRoot = Get-ChildItem $configurationRoot -Directory | Where-Object Name -Like 'net*-windows*' | Sort-Object Name -Descending | Select-Object -First 1
if (-not $tfmRoot) { throw "Build output was not found under $configurationRoot." }
$outputRoot = Join-Path $tfmRoot.FullName 'win-x64'
if (-not (Test-Path $outputRoot)) { $outputRoot = $tfmRoot.FullName }

if ($Detach) {
    winapp run $outputRoot --detach --json
} else {
    winapp run $outputRoot --debug-output
}
