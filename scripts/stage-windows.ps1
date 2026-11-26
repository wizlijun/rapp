# Builds the Windows programs and lays them out the way an installed copy looks (spec 5.1):
#
#   <Out>\current            one line: app-<workspace version>
#   <Out>\bin\rapp.exe       the command (a copy of rapp-cli.exe)
#   <Out>\app-<version>\...  the programs of this version
#
# Usage: scripts\stage-windows.ps1 [-Release] [-Gui] [-Out <dir>]
#   -Release  cargo build --release (default: debug)
#   -Gui      also copy the Flutter Release folder (run `flutter build windows --release` in gui\ first)
#   -Out      default .build\windows-stage
#
# A program that is not staged is not found by bins::find, so the service reports that capability
# as absent. That is how a phase-A machine is honestly "controller only". Phase G's packaging
# starts from this script. Windows PowerShell 5.1; ASCII only.
[CmdletBinding()]
param(
    [switch]$Release,
    [switch]$Gui,
    [string]$Out = ''
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$rust = Join-Path $repo 'rust'
if ($Out -eq '') { $Out = Join-Path $repo '.build\windows-stage' }
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false

function Get-WorkspaceVersion {
    $inPackage = $false
    foreach ($line in Get-Content -LiteralPath (Join-Path $rust 'Cargo.toml')) {
        if ($line -match '^\s*\[') { $inPackage = ($line.Trim() -eq '[workspace.package]'); continue }
        if ($inPackage -and $line -match '^\s*version\s*=\s*"([^"]+)"') { return $Matches[1] }
    }
    throw 'no version under [workspace.package] in rust\Cargo.toml'
}

function Invoke-Native([string]$exe, [string[]]$arguments, [string]$dir) {
    Push-Location -LiteralPath $dir
    try {
        & $exe @arguments
        if ($LASTEXITCODE -ne 0) { throw "$exe $($arguments -join ' ') exited with $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}

# Package -> built file -> staged name. Flip a commented row when its phase is done.
$programs = @(
    @{ Package = 'rapp-service';     Built = 'rapp-service.exe';  Staged = 'rapp-service.exe' },
    @{ Package = 'rapp-hub';         Built = 'rapp-hub.exe';      Staged = 'rapp-hub.exe' },
    @{ Package = 'rapp-client-core'; Built = 'rapp-session.exe';  Staged = 'rapp-session.exe' },
    @{ Package = 'rapp-cli';         Built = 'rapp-cli.exe';      Staged = 'rapp-cli.exe' }
    # Not staged yet:
    # @{ Package = 'rapp-svc-windows';  Built = 'rapp-svc.exe';          Staged = 'rapp-svc.exe' }   # phase C
    # @{ Package = 'rapp-host-windows'; Built = 'rapp-host-windows.exe'; Staged = 'rapp-host.exe' }  # phase D
    # @{ Package = 'rapp-term';         Built = 'rapp-term.exe';         Staged = 'rapp-term.exe' }  # phase E, plus the ConPTY files
    # @{ Package = 'rapp-speech-linux'; Built = 'rapp-speech.exe';       Staged = 'rapp-speech.exe' }  # phase H
)

$version = Get-WorkspaceVersion
$appName = "app-$version"
$buildProfile = if ($Release) { 'release' } else { 'debug' }

# Build: explicit packages, like scripts/build-linux.sh.
$cargoArgs = @('build')
if ($Release) { $cargoArgs += '--release' }
foreach ($p in $programs) { $cargoArgs += @('-p', $p.Package) }
Invoke-Native 'cargo' $cargoArgs $rust

# Copy from the target directory cargo really used (CARGO_TARGET_DIR, config), never a guess.
Push-Location -LiteralPath $rust
try {
    $metadata = (& cargo metadata --no-deps --format-version 1) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw "cargo metadata exited with $LASTEXITCODE" }
} finally {
    Pop-Location
}
$targetDir = (ConvertFrom-Json $metadata).target_directory
$builtDir = Join-Path $targetDir $buildProfile

# Lay out. The version directory is rebuilt from scratch so nothing stale stays in it.
$appDir = Join-Path $Out $appName
$binDir = Join-Path $Out 'bin'
if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

if ($Gui) {
    $flutterOut = Join-Path $repo 'gui\build\windows\x64\runner\Release'
    if (-not (Test-Path -LiteralPath (Join-Path $flutterOut 'rapp.exe'))) {
        throw "no Flutter build at $flutterOut (run: flutter build windows --release, in gui\)"
    }
    Copy-Item -Path (Join-Path $flutterOut '*') -Destination $appDir -Recurse -Force
    # The runner is still called rapp (phase C renames it); in the stage it is the interface.
    Move-Item -LiteralPath (Join-Path $appDir 'rapp.exe') -Destination (Join-Path $appDir 'rapp-gui.exe') -Force
}

foreach ($p in $programs) {
    $from = Join-Path $builtDir $p.Built
    if (-not (Test-Path -LiteralPath $from)) { throw "cargo did not leave $from" }
    Copy-Item -LiteralPath $from -Destination (Join-Path $appDir $p.Staged) -Force
}
Copy-Item -LiteralPath (Join-Path $appDir 'rapp-cli.exe') -Destination (Join-Path $binDir 'rapp.exe') -Force

# One line, no BOM, no trailing newline: readers take the whole file as the directory name.
[System.IO.File]::WriteAllText((Join-Path $Out 'current'), $appName, (New-Object System.Text.UTF8Encoding $false))

# Self-check.
$bad = @()
$expected = @($programs | ForEach-Object { $_.Staged })
if ($Gui) { $expected += 'rapp-gui.exe' }
foreach ($name in $expected) {
    if (-not (Test-Path -LiteralPath (Join-Path $appDir $name))) { $bad += "missing $appName\$name" }
}
if (-not (Test-Path -LiteralPath (Join-Path $binDir 'rapp.exe'))) { $bad += 'missing bin\rapp.exe' }
$said = (& (Join-Path $appDir 'rapp-cli.exe') --version | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $said -ne "rapp $version") { $bad += "rapp-cli.exe --version said '$said', expected 'rapp $version'" }
$current = [System.IO.File]::ReadAllText((Join-Path $Out 'current'))
if ($current -ne $appName) { $bad += "current holds '$current', expected '$appName'" }

if ($bad.Count -gt 0) {
    foreach ($b in $bad) { Write-Host "stage: $b" }
    exit 1
}
Write-Host "stage: ok $Out\$appName ($buildProfile)"
exit 0
