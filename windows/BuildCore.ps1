param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'

$windowsRoot = $PSScriptRoot
$repositoryRoot = Split-Path $windowsRoot -Parent
$coreRoot = Join-Path $repositoryRoot 'core'
$revision = 'd2c403db4db249c70586818f5bfd19018c979a38'
$toolRoot = Join-Path $coreRoot "target\boltffi-csharp-$revision"
$sourceRoot = Join-Path $toolRoot 'source'
$patchPath = Join-Path $windowsRoot 'patches\boltffi-0.28-csharp.patch'
$projectPath = Join-Path $windowsRoot 'BudgetWarden.Windows.csproj'
$nugetConfig = Join-Path $repositoryRoot 'NuGet.config'

foreach ($command in @('cargo', 'git', 'dotnet')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is required to build the Windows core bindings."
    }
}

if (-not (Get-Command link.exe -ErrorAction SilentlyContinue)) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        throw 'Visual Studio with the Desktop development with C++ workload is required.'
    }

    $vsPath = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    $devShell = Join-Path $vsPath 'Common7\Tools\Launch-VsDevShell.ps1'
    if (-not $vsPath -or -not (Test-Path $devShell)) {
        throw 'Visual Studio with the Desktop development with C++ workload is required.'
    }
    & $devShell -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
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

git -C $sourceRoot apply --check $patchPath 2>$null
if ($LASTEXITCODE -eq 0) {
    git -C $sourceRoot apply $patchPath
    if ($LASTEXITCODE -ne 0) { throw 'Unable to apply the C# generator patch.' }
} else {
    git -C $sourceRoot apply --reverse --check $patchPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'The BoltFFI source does not match either the pristine or patched pinned revision.'
    }
}

cargo build --manifest-path (Join-Path $sourceRoot 'Cargo.toml') --package boltffi_cli --release
if ($LASTEXITCODE -ne 0) { throw 'BoltFFI CLI build failed.' }

$boltffi = Join-Path $sourceRoot 'target\release\boltffi.exe'
$packArgs = @('pack', 'csharp', '--regenerate')
if ($Release) { $packArgs += '--release' }

Push-Location $coreRoot
try {
    & $boltffi @packArgs
    if ($LASTEXITCODE -ne 0) { throw 'C# binding generation failed.' }
} finally {
    Pop-Location
}

$manifest = Get-Content (Join-Path $coreRoot 'Cargo.toml') -Raw
$version = [regex]::Match($manifest, '(?m)^version\s*=\s*"([^"]+)"').Groups[1].Value
$packagePath = Join-Path $coreRoot "dist\csharp\packages\bw_core.$version.nupkg"
if (-not (Test-Path $packagePath)) {
    throw "Expected NuGet package was not generated: $packagePath"
}

$globalPackagesLine = dotnet nuget locals global-packages --list | Select-Object -First 1
$globalPackagesRoot = ($globalPackagesLine -replace '^global-packages:\s*', '').Trim()
$cachedPackage = Join-Path $globalPackagesRoot "bw_core\$version"
if ($globalPackagesRoot -and (Test-Path $cachedPackage)) {
    Remove-Item -LiteralPath $cachedPackage -Recurse -Force
}

dotnet restore $projectPath --configfile $nugetConfig --force --no-cache
if ($LASTEXITCODE -ne 0) { throw 'Windows app restore failed.' }

Write-Host "Generated $packagePath" -ForegroundColor Green
