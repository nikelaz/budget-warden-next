param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'

$androidRoot = $PSScriptRoot
$repositoryRoot = Split-Path $androidRoot -Parent
$coreRoot = Join-Path $repositoryRoot 'core'
$revision = 'd2c403db4db249c70586818f5bfd19018c979a38'
$toolRoot = Join-Path $coreRoot "target\boltffi-android-$revision"
$sourceRoot = Join-Path $toolRoot 'source'

foreach ($commandName in @('cargo', 'git', 'rustup')) {
    if (-not (Get-Command $commandName -ErrorAction SilentlyContinue)) {
        throw "$commandName is required to build the Android core bindings."
    }
}

$localPropertiesPath = Join-Path $androidRoot 'local.properties'
$androidSdkPath = $env:ANDROID_SDK_ROOT
if (-not $androidSdkPath) {
    $androidSdkPath = $env:ANDROID_HOME
}
if (-not $androidSdkPath -and (Test-Path $localPropertiesPath)) {
    $sdkLine = Get-Content $localPropertiesPath | Where-Object { $_ -match '^sdk\.dir=' } | Select-Object -First 1
    if ($sdkLine) {
        $androidSdkPath = ($sdkLine -replace '^sdk\.dir=', '') -replace '\\:', ':' -replace '\\\\', '\'
    }
}
if (-not $androidSdkPath -or -not (Test-Path $androidSdkPath)) {
    throw 'Android SDK not found. Set ANDROID_SDK_ROOT or configure android/local.properties.'
}

$ndkRoot = Join-Path $androidSdkPath 'ndk'
$androidNdk = Get-ChildItem $ndkRoot -Directory -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    Select-Object -First 1
if (-not $androidNdk) {
    throw 'Android NDK not found. Install it from Android Studio SDK Manager.'
}

if (-not (Test-Path (Join-Path $sourceRoot '.git'))) {
    New-Item -ItemType Directory -Force -Path $toolRoot | Out-Null
    git clone --filter=blob:none https://github.com/boltffi/boltffi.git $sourceRoot
    if ($LASTEXITCODE -ne 0) { throw 'Unable to clone BoltFFI.' }
}

$actualRevision = git -C $sourceRoot rev-parse HEAD
if ($actualRevision -ne $revision) {
    git -C $sourceRoot fetch origin $revision
    if ($LASTEXITCODE -ne 0) { throw 'Unable to fetch the pinned BoltFFI revision.' }
    git -C $sourceRoot checkout --detach $revision
    if ($LASTEXITCODE -ne 0) { throw 'Unable to check out the pinned BoltFFI revision.' }
}

cargo build --manifest-path (Join-Path $sourceRoot 'Cargo.toml') --package boltffi_cli --release
if ($LASTEXITCODE -ne 0) { throw 'BoltFFI CLI build failed.' }

$boltffi = Join-Path $sourceRoot 'target\release\boltffi.exe'
$packArguments = @('pack', 'android', '--regenerate')
if ($Release) { $packArguments += '--release' }

$previousNdk = $env:ANDROID_NDK_HOME
$env:ANDROID_NDK_HOME = $androidNdk.FullName
Push-Location $coreRoot
try {
    & $boltffi @packArguments
    if ($LASTEXITCODE -ne 0) { throw 'Android binding generation failed.' }
} finally {
    Pop-Location
    $env:ANDROID_NDK_HOME = $previousNdk
}

$kotlinBinding = Join-Path $coreRoot 'dist\android\kotlin\com\lazarovco\budgetwarden\core\BwCore.kt'
$nativeLibrary = Join-Path $coreRoot 'dist\android\jniLibs\arm64-v8a\libbw_core.so'
if (-not (Test-Path $kotlinBinding) -or -not (Test-Path $nativeLibrary)) {
    throw 'BoltFFI completed without producing the expected Android artifacts.'
}

Write-Host "Generated Android bindings in $(Join-Path $coreRoot 'dist\android')" -ForegroundColor Green
