# Domain: LTE cell identity, observation continuity and bounded transition history.

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
function Add-HandoverLog($Log, $Cell, [string]$Timestamp, [bool]$ObservationFailed = $false) {
    if ($null -eq $Log) { return }
    if ($ObservationFailed -or $null -eq $cell -or
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
                Number = $Log.Count; Timestamp = $Timestamp; From = $previous; To = $current
            })
        while ($Log.Entries.Count -gt $Log.MaxEntries) { $Log.Entries.RemoveAt(0) }
    }
    $Log.Previous = $current
}
