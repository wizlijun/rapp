# The Windows gate (spec 14.3 steps 1-3; with -Build also step 4).
#
#   1. cargo test --workspace --no-fail-fast  (rust\, four crates excluded)
#   2. cargo clippy --workspace --all-targets -- -D warnings  (rust\, same excludes)
#   3. flutter analyze, then flutter test  (gui\)
#   4. -Build only: flutter build windows --release (gui\), then stage-windows.ps1 -Release -Gui
#
# Every step runs even after one fails. One line per step on the screen (ok / FAILED); the full
# output goes to .build-logs\check-windows.log, whose last line is EXIT=<0|1>; the script exits
# with that status. Flutter: on PATH, or set FLUTTER to flutter.bat. Windows PowerShell 5.1;
# ASCII only.
[CmdletBinding()]
param(
    [switch]$Build
)
$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$rust = Join-Path $repo 'rust'
$gui = Join-Path $repo 'gui'
$logDir = Join-Path $repo '.build-logs'
$log = Join-Path $logDir 'check-windows.log'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
[System.IO.File]::WriteAllText($log, '', (New-Object System.Text.UTF8Encoding $false))

$flutter = if ($env:FLUTTER) { $env:FLUTTER } else { 'flutter' }
# rapp-relay: its admin socket is a Unix socket. The other three are Linux- or iOS-only.
$excludes = @('--exclude', 'rapp-relay', '--exclude', 'rapp-host-linux', '--exclude', 'rapp-client-gtk', '--exclude', 'rapp-hub-ffi')

function Write-Log([string]$text) {
    [System.IO.File]::AppendAllText($log, $text + "`r`n", (New-Object System.Text.UTF8Encoding $false))
}

# Runs one command in a directory; its stdout and stderr go to the log. True when it exited 0.
function Invoke-Logged([string]$dir, [string]$exe, [string[]]$arguments) {
    Write-Log "### $dir> $exe $($arguments -join ' ')"
    # A missing program would leave $LASTEXITCODE from the step before; catch it here.
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
        Write-Log "### not found: $exe"
        return $false
    }
    Push-Location -LiteralPath $dir
    try {
        # 2>&1 turns stderr lines into error records in 5.1; "$_" gives back their text.
        & $exe @arguments 2>&1 | ForEach-Object { Write-Log "$_" }
        $code = $LASTEXITCODE
    } catch {
        Write-Log "could not run ${exe}: $($_.Exception.Message)"
        $code = 1
    } finally {
        Pop-Location
    }
    Write-Log "### exit $code"
    return ($code -eq 0)
}

$failed = $false
function Step([string]$name, [scriptblock]$body) {
    $ok = & $body
    if ($ok -eq $true) {
        Write-Host "ok      $name"
    } else {
        Write-Host "FAILED  $name"
        $script:failed = $true
    }
}

Step 'cargo test' {
    Invoke-Logged $rust 'cargo' (@('test', '--workspace', '--no-fail-fast') + $excludes)
}
Step 'cargo clippy' {
    Invoke-Logged $rust 'cargo' (@('clippy', '--workspace', '--all-targets') + $excludes + @('--', '-D', 'warnings'))
}
Step 'flutter analyze + test' {
    $a = Invoke-Logged $gui $flutter @('analyze')
    $t = Invoke-Logged $gui $flutter @('test')
    ($a -and $t)
}
if ($Build) {
    Step 'flutter build windows + stage' {
        $b = Invoke-Logged $gui $flutter @('build', 'windows', '--release')
        $s = $false
        if ($b) {
            $s = Invoke-Logged $repo 'powershell.exe' @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'stage-windows.ps1'), '-Release', '-Gui')
        }
        ($b -and $s)
    }
}

$exit = if ($failed) { 1 } else { 0 }
Write-Log "EXIT=$exit"
Write-Host "log: $log"
exit $exit
