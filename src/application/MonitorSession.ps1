# Application: monitoring session use case (sample -> history -> CSV), UI independent.
#
# Config:  [pscustomobject]@{ Interval = <sec>; Count = <n, 0 = infinite>; CsvPath = <path or ""> }
# Session: Modem, Config, Summary, Snapshot (latest), Iteration,
#          History (ordered name -> List[double], all series the same length, NaN = missing;
#          see Add-SignalHistory for the series),
#          DowngradeLog (2G/3G findings seen so far, see Add-DowngradeLog)

function Initialize-MonitorSession($Modem, $Config, [int]$HistoryMax = 600) {
    if ($Config.CsvPath) { Initialize-SnapshotLog $Config.CsvPath }
    return [pscustomobject]@{
        Modem        = $Modem
        Config       = $Config
        Summary      = Get-ModemSummary $Modem
        Snapshot     = $null
        History      = New-SignalHistory
        DowngradeLog = [pscustomobject]@{ AlertCount = 0; WarningCount = 0; Last = $null; LastLevel = $null; LastReasons = @() }
        HistoryMax   = $HistoryMax
        Iteration    = 0
    }
}

# Takes one sample and updates the session (history, CSV).
function Invoke-MonitorSample($Session) {
    $Session.Iteration++
    $Session.Snapshot = Get-LteSnapshot $Session.Modem
    Add-SignalHistory -Session $Session -Snapshot $Session.Snapshot
    Add-DowngradeLog -Session $Session -Snapshot $Session.Snapshot
    if ($Session.Config.CsvPath) { Add-SnapshotLog $Session.Config.CsvPath $Session.Snapshot }
}

function Test-MonitorComplete($Session) {
    return ($Session.Config.Count -gt 0 -and $Session.Iteration -ge $Session.Config.Count)
}

function New-SignalHistory {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    $history = [ordered]@{}
    foreach ($name in 'Rsrp', 'Rsrq', 'Rssnr', 'RxKB', 'TxKB', 'TempC') {
        $history[$name] = New-Object System.Collections.Generic.List[double]
    }
    return $history
}

# History tracks the primary serving cell only (index 0), so carrier aggregation
# SCells do not get interleaved into one series. All series are appended together
# (NaN when a value is unavailable) so they stay time-aligned; a sample without an
# LTE serving cell is skipped for every series. Oldest samples beyond HistoryMax are dropped.
#   Rsrp (dBm), Rsrq (dB), Rssnr (dB), RxKB / TxKB (KB/s), TempC (C)
function Add-SignalHistory($Session, $Snapshot) {
    if ($Snapshot.Serving.Count -eq 0) { return }
    $cell = $Snapshot.Serving[0]
    $sample = @{
        Rsrp  = $cell.RsrpDbm
        Rsrq  = $cell.RsrqDb
        Rssnr = $Snapshot.Rssnr
        RxKB  = $Snapshot.RxKB
        TxKB  = $Snapshot.TxKB
        TempC = $Snapshot.TempC
    }
    foreach ($name in $Session.History.Keys) {
        $h = $Session.History[$name]
        $value = $sample[$name]
        $h.Add($(if ($null -eq $value) { [double]::NaN } else { [double]$value }))
        while ($h.Count -gt $Session.HistoryMax) { $h.RemoveAt(0) }
    }
}

# Keeps 2G/3G findings after they disappear, so a brief downgrade is not missed on screen.
function Add-DowngradeLog($Session, $Snapshot) {
    $finding = $Snapshot.Downgrade
    if ($null -eq $finding -or $finding.Level -eq 'None') { return }
    $log = $Session.DowngradeLog
    if ($finding.Level -eq 'Alert') { $log.AlertCount++ } else { $log.WarningCount++ }
    $log.Last = $Snapshot.Timestamp
    $log.LastLevel = $finding.Level
    $log.LastReasons = $finding.Reasons
}
