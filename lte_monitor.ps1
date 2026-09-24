#Requires -Version 7.4
# LTE Signal Monitor (TUI) for Windows mobile broadband modems (tested: Fibocom L860-GL)
# Usage: .\lte_monitor.ps1 [-Interval 0] [-Count 0] [-CsvPath "log.csv"] [-AtPort COM7] [-Gps]
# Interval=0 means back-to-back sampling (each sample still takes ~1s for counters).
# Count=0 means infinite loop. CsvPath enables CSV logging (one row per sample, see src/application/SnapshotLog.ps1).
# AT commands (neighbors, temperature, SINR, CA) go over a vendor MBIM service found automatically;
# AtPort uses that serial AT port instead (see docs/modem-support.md).
# Gps shows Windows satellite fixes. Nmea (implies Gps) also lists satellites from the GNSS
# driver through a helper process elevated with UAC at startup (see docs/gps.md).
# Keys:  q / Esc / Ctrl+C = quit,  p = pause/resume,  r = refresh now,
#        R = reset statistics (history charts, handover history, 2G/3G log),
#        1-6 = show/hide a history chart (RSRP/RSRQ/SNR/RX/TX/Temp),  g = show/hide all charts
#        h = handover history, s = satellite list (-Nmea),
#        Up/Down = chart height, newer/older handovers or scroll satellites
# Requires PowerShell 7.4+ (Windows). Run .\setup.ps1 once beforehand to download
# the WinRT projection DLLs into .\lib (Windows PowerShell 5.1 is not supported).
# When stdin/stdout is redirected, falls back to plain sequential output.
#
# Entry point only: parse args, load src/, wire dependencies, pick the UI.
# Layers (src/<layer>/*.ps1, lower layers never call upper ones):
#   domain rules <- infrastructure adapters / application use cases <- presentation

# CmdletBinding rejects unknown or misspelled options instead of silently ignoring them.
[CmdletBinding()]
param(
    [ValidateRange(0, 86400)][int]$Interval = 0,
    [ValidateRange(0, [int]::MaxValue)][int]$Count = 0,
    [string]$CsvPath = '',
    [ValidatePattern('^(COM\d+)?$')][string]$AtPort = '',
    [switch]$Gps,
    [Alias('Nema')][switch]$Nmea
)

# Shared composition root; definitions must load into this script's scope.
. (Join-Path $PSScriptRoot 'src/Load.ps1')

try { Import-WinRtProjection -LibDir (Join-Path $PSScriptRoot 'lib') }
catch {
    Write-Error $_.Exception.Message
    exit 1
}

$modem = Get-DefaultModem
if (-not $modem) {
    Write-Error 'Modem not found'
    exit 1
}

$config = [pscustomobject]@{ Interval = $Interval; Count = $Count; CsvPath = $CsvPath; AtPort = $AtPort }
$session = Initialize-MonitorSession -Modem $modem -Config $config

try {
    if ($Gps -or $Nmea) { $session.GpsReceiver = Start-GpsReceiver }
    # Before the TUI takes the screen: the UAC prompt blocks until it is answered.
    if ($Nmea) { $session.NmeaReceiver = Start-NmeaReceiver }
    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Invoke-PlainMonitor $session
    }
    else {
        Invoke-TuiMonitor $session
        Write-Output "LTE monitor stopped after $($session.Iteration) sample(s)."
    }
}
finally {
    try { Stop-NmeaReceiver $session.NmeaReceiver }
    finally { Stop-GpsReceiver $session.GpsReceiver }
}
exit 0
