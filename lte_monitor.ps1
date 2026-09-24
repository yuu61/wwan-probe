# Fibocom L860-GL LTE Signal Monitor (TUI)
# Usage: .\lte_monitor.ps1 [-Interval 0] [-Count 0] [-CsvPath "log.csv"]
# Interval=0 means back-to-back sampling (each sample still takes ~1s for counters).
# Count=0 means infinite loop. CsvPath enables CSV logging.
# Keys:  q / Esc / Ctrl+C = quit,  p = pause/resume,  r = refresh now
# Note: Requires Windows PowerShell 5.1 for WinRT API access.
#       When run from PowerShell 7+, automatically re-launches with powershell.exe (5.1).
#       When stdin/stdout is redirected, falls back to plain sequential output.
#
# Entry point only: parse args, load src/, wire dependencies, pick the UI.
# Layers (src/<layer>/*.ps1, lower layers never call upper ones):
#   domain -> infrastructure -> application -> presentation

param(
    [ValidateRange(0, 86400)][int]$Interval = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$Count = 0,
    [string]$CsvPath = ""
)

# PowerShell 7+ does not support WinRT type loading natively.
# Re-launch this script under Windows PowerShell 5.1 (powershell.exe).
# This must run before src\infrastructure\WinRt.ps1 is dot-sourced.
if ($PSVersionTable.PSVersion.Major -ge 6) {
    # Forward only explicitly given parameters so defaults are decided in one place (param block).
    $args5 = @('-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
    foreach ($p in $PSBoundParameters.GetEnumerator()) { $args5 += "-$($p.Key)"; $args5 += $p.Value }
    & powershell.exe $args5
    exit $LASTEXITCODE
}

# Load order matters. Dot-source at top level (not inside a function) so the
# definitions land in this script's scope.
$sources = @(
    'domain\Signal.ps1'
    'domain\Band.ps1'
    'infrastructure\WinRt.ps1'
    'infrastructure\Modem.ps1'
    'infrastructure\PerfCounter.ps1'
    'infrastructure\CsvFile.ps1'
    'application\Snapshot.ps1'
    'application\SnapshotLog.ps1'
    'application\MonitorSession.ps1'
    'presentation\Gauge.ps1'
    'presentation\Frame.ps1'
    'presentation\ConsoleRenderer.ps1'
    'presentation\PlainMonitor.ps1'
    'presentation\TuiMonitor.ps1'
)
foreach ($src in $sources) { . (Join-Path $PSScriptRoot "src\$src") }

$modem = Get-DefaultModem
if (-not $modem) {
    Write-Error "Modem not found"
    exit 1
}

$config = [pscustomobject]@{ Interval = $Interval; Count = $Count; CsvPath = $CsvPath }
$session = Initialize-MonitorSession -Modem $modem -Config $config

if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    Invoke-PlainMonitor $session
}
else {
    Invoke-TuiMonitor $session
    Write-Output "LTE monitor stopped after $($session.Iteration) sample(s)."
}
exit 0
