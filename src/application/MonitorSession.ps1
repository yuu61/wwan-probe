# Application: monitoring session use case (sample -> history -> CSV), UI independent.
#
# Config:  [pscustomobject]@{ Interval = <sec>; Count = <n, 0 = infinite>; CsvPath = <path or ""> }
# Session: Modem, Config, Summary, Snapshot (latest), Iteration,
#          History (ordered name -> List[double], all series the same length, NaN = missing;
#          see Add-SignalHistory for the series),
#          DowngradeLog (2G/3G findings seen so far, see Add-DowngradeLog), HandoverLog

function Initialize-MonitorSession($Modem, $Config, [int]$HistoryMax = 600) {
    if ($Config.CsvPath) { Initialize-SnapshotLog $Config.CsvPath }
    return [pscustomobject]@{
        Modem        = $Modem
        Config       = $Config
        Summary      = Get-ModemSummary $Modem
        Snapshot     = $null
        History      = New-SignalHistory
        HandoverLog  = New-HandoverLog
        DowngradeLog = [pscustomobject]@{ AlertCount = 0; WarningCount = 0; Last = $null; LastLevel = $null; LastReasons = @() }
        HistoryMax   = $HistoryMax
        Iteration    = 0
    }
}

# Takes one sample and updates the session (history, CSV).
function Invoke-MonitorSample($Session) {
    Add-MonitorSnapshot $Session (Get-LteSnapshot $Session.Modem)
}

# Commits a completed sample on the UI thread, so rendering never sees partial history.
function Add-MonitorSnapshot($Session, $Snapshot) {
    $Session.Iteration++
    $Session.Snapshot = $Snapshot
    Add-SignalHistory -Session $Session -Snapshot $Session.Snapshot
    Add-DowngradeLog -Session $Session -Snapshot $Session.Snapshot
    Add-HandoverLog -Log $Session.HandoverLog -Snapshot $Session.Snapshot
    if ($Session.Config.CsvPath) { Add-SnapshotLog $Session.Config.CsvPath $Session.Snapshot }
}

# Bounded session-local cell-change history. Count includes entries already evicted.
function New-HandoverLog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([ValidateRange(1, 10000)][int]$MaxEntries = 100)

    return [pscustomobject]@{
        Entries    = [System.Collections.Generic.List[object]]::new()
        Previous   = $null
        Count      = 0
        MaxEntries = $MaxEntries
    }
}

# Compare PLMN + Cell ID of the unfiltered first LTE serving cell, matching the
# primary-cell convention used by this monitor. Never promote an SCell because
# the primary has no signal measurement. Missing/failed observations break the
# baseline: a later reconnection cannot establish a directly observed handover.
function Add-HandoverLog($Log, $Snapshot) {
    if ($null -eq $Log) { return }
    $cell = $Snapshot.PrimaryCell
    if ($Snapshot.Error -or $null -eq $cell -or
        [string]::IsNullOrWhiteSpace($cell.Provider) -or $null -eq $cell.CellId -or
        $cell.CellId -lt 0 -or $cell.CellId -gt 0x0FFFFFFF) {
        $Log.Previous = $null
        return
    }
    # Copy values so future snapshots cannot mutate previously recorded events.
    $current = [pscustomobject]@{
        Provider = $cell.Provider; CellId = $cell.CellId; Band = $cell.Band
        Earfcn = $cell.Earfcn; Pci = $cell.Pci; Tac = $cell.Tac; RsrpDbm = $cell.RsrpDbm
    }
    $previous = $Log.Previous
    if ($null -ne $previous -and
        ($previous.Provider -ne $current.Provider -or $previous.CellId -ne $current.CellId)) {
        $Log.Count++
        $Log.Entries.Add([pscustomobject]@{
                Number = $Log.Count; Timestamp = $Snapshot.Timestamp; From = $previous; To = $current
            })
        while ($Log.Entries.Count -gt $Log.MaxEntries) { $Log.Entries.RemoveAt(0) }
    }
    $Log.Previous = $current
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
