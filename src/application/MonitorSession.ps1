# Application: monitoring session use case (sample -> history -> CSV), UI independent.
#
# Config:  [pscustomobject]@{ Interval = <sec>; Count = <n, 0 = infinite>; CsvPath = <path or ""> }
# Session: Modem, Config, Summary, Snapshot (latest), History (primary cell RSRP), Iteration

function Initialize-MonitorSession($Modem, $Config, [int]$HistoryMax = 600) {
    if ($Config.CsvPath) { Initialize-SnapshotLog $Config.CsvPath }
    return [pscustomobject]@{
        Modem      = $Modem
        Config     = $Config
        Summary    = Get-ModemSummary $Modem
        Snapshot   = $null
        History    = New-Object System.Collections.Generic.List[int]
        HistoryMax = $HistoryMax
        Iteration  = 0
    }
}

# Takes one sample and updates the session (history, CSV).
function Invoke-MonitorSample($Session) {
    $Session.Iteration++
    $Session.Snapshot = Get-LteSnapshot $Session.Modem
    Add-RsrpHistory -History $Session.History -Snapshot $Session.Snapshot -MaxCount $Session.HistoryMax
    if ($Session.Config.CsvPath) { Add-SnapshotLog $Session.Config.CsvPath $Session.Snapshot }
}

function Test-MonitorComplete($Session) {
    return ($Session.Config.Count -gt 0 -and $Session.Iteration -ge $Session.Config.Count)
}

# History tracks the primary serving cell only (index 0), so carrier aggregation
# SCells do not get interleaved into one series. Oldest samples beyond MaxCount are dropped.
function Add-RsrpHistory([System.Collections.Generic.List[int]]$History, $Snapshot, [int]$MaxCount = 600) {
    if ($Snapshot.Serving.Count -gt 0) { $History.Add([int]$Snapshot.Serving[0].RsrpDbm) }
    while ($History.Count -gt $MaxCount) { $History.RemoveAt(0) }
}
