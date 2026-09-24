# Application: monitoring session use case (sample -> history -> CSV), UI independent.
#
# Config:  [pscustomobject]@{ Interval = <sec>; Count = <n, 0 = infinite>; CsvPath = <path or "">; AtPort = <"COMx" or ""> }
# Session: Modem, Config, Summary, Snapshot (latest), Iteration,
#          History (ordered name -> List[double], all series the same length, NaN = missing;
#          see Add-SignalHistory for the series),
#          DowngradeLog (2G/3G findings seen so far, see Add-DowngradeLog), HandoverLog
# Statistics (History, HandoverLog, DowngradeLog) can be cleared with Reset-MonitorStatistic.

function Initialize-MonitorSession($Modem, $Config, [int]$HistoryMax = 600) {
    if ($Config.CsvPath) { Initialize-SnapshotLog $Config.CsvPath }
    return [pscustomobject]@{
        Modem        = $Modem
        Config       = $Config
        Summary      = Get-ModemSummary $Modem $Config.AtPort
        Snapshot     = $null
        GpsReceiver  = $null
        NmeaReceiver = $null
        History      = New-SignalHistory
        HandoverLog  = New-HandoverLog
        DowngradeLog = New-DowngradeLog
        HistoryMax   = $HistoryMax
        Iteration    = 0
    }
}

# Clears the history charts, handover history and 2G/3G log. Iteration (progress toward
# Config.Count), the latest snapshot and the CSV log are kept. The handover baseline (the
# current cell) is kept too, so a cell change across the reset is still detected.
function Reset-MonitorStatistic {
    # In-memory session state only; ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Session)

    # Clear every series so they stay time-aligned.
    foreach ($series in $Session.History.Values) { $series.Clear() }
    $Session.HandoverLog.Entries.Clear()
    $Session.HandoverLog.Count = 0
    $Session.DowngradeLog = New-DowngradeLog
}

# Takes one sample and updates the session (history, CSV).
function Invoke-MonitorSample($Session) {
    Add-MonitorSnapshot $Session (Get-LteSnapshot $Session.Modem $Session.Summary.At $Session.GpsReceiver $Session.NmeaReceiver)
}

# Commits a completed sample on the UI thread, so rendering never sees partial history.
function Add-MonitorSnapshot($Session, $Snapshot) {
    $Session.Iteration++
    $Session.Snapshot = $Snapshot
    Add-SignalHistory -Session $Session -Snapshot $Session.Snapshot
    Add-DowngradeLog -Session $Session -Snapshot $Session.Snapshot
    Add-HandoverLog -Log $Session.HandoverLog -Cell $Snapshot.PrimaryCell -Timestamp $Snapshot.Timestamp -ObservationFailed ([bool]$Snapshot.Error)
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

# History tracks the explicitly selected primary serving cell only, so carrier aggregation
# SCells do not get interleaved into one series. All series are appended together
# (NaN when a value is unavailable) so gaps stay visible and modem-wide measurements
# survive a missing LTE cell. Oldest samples beyond HistoryMax are dropped.
#   Rsrp (dBm), Rsrq (dB), Rssnr (dB), RxKB / TxKB (KB/s), TempC (C)
function Add-SignalHistory($Session, $Snapshot) {
    $cell = $Snapshot.PrimaryCell
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

function New-DowngradeLog {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    return [pscustomobject]@{ AlertCount = 0; WarningCount = 0; Last = $null; LastLevel = $null; LastReasons = @() }
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
