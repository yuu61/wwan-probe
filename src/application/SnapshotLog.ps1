# Application: snapshot -> CSV logging (column order is part of the output contract).
#
# One row per sample, including samples without an LTE serving cell (cell columns empty),
# so gaps stay visible. Cell columns are the primary serving cell (Serving[0]); CA secondary
# cells are '+'-joined lists in the SCell_* columns. Unavailable values are empty.

$script:SnapshotLogColumns = @(
    'Timestamp'
    'RSRP_dBm', 'RSRQ_dB', 'RSSNR_dB'
    'Band', 'EARFCN', 'PCI', 'CellID', 'TAC', 'TA'
    'Provider', 'DataClass'
    'CA_Cells', 'CA_BW_MHz'
    'SCell_Band', 'SCell_EARFCN', 'SCell_PCI', 'SCell_RSRP_dBm', 'SCell_RSRQ_dB'
    'RX_KBps', 'TX_KBps', 'BW_Mbps'
    'Temp_C'
    'Downgrade', 'Downgrade_Reason'
    'Error'
)

function Initialize-SnapshotLog([string]$Path) {
    Initialize-CsvFile -Path $Path -Columns $script:SnapshotLogColumns
}

function Add-SnapshotLog([string]$Path, $Snapshot) {
    $row = ConvertTo-SnapshotLogRow $Snapshot
    Add-CsvRow -Path $Path -Fields @($script:SnapshotLogColumns | ForEach-Object { $row[$_] })
}

# Snapshot -> @{ column = value } for $script:SnapshotLogColumns (missing key = empty field).
function ConvertTo-SnapshotLogRow($Snapshot) {
    $join = { param($items) if (@($items).Count -gt 0) { @($items) -join '+' } }
    $pcell = $Snapshot.Serving | Select-Object -First 1
    $scells = @($Snapshot.Serving | Select-Object -Skip 1)

    $errors = @()
    if ($Snapshot.Error) { $errors += "WinRT: $($Snapshot.Error)" }
    if ($Snapshot.AtError) { $errors += "AT: $($Snapshot.AtError)" }

    $row = @{
        Timestamp        = $Snapshot.Timestamp
        RSSNR_dB         = $Snapshot.Rssnr
        Provider         = $Snapshot.ProviderId
        DataClass        = $Snapshot.DataClass
        CA_Cells         = $Snapshot.Ca.Cells
        CA_BW_MHz        = & $join $Snapshot.Ca.BandwidthsMHz
        SCell_Band       = & $join $scells.Band
        SCell_EARFCN     = & $join $scells.Earfcn
        SCell_PCI        = & $join $scells.Pci
        SCell_RSRP_dBm   = & $join $scells.RsrpDbm
        SCell_RSRQ_dB    = & $join $scells.RsrqDb
        RX_KBps          = $Snapshot.RxKB
        TX_KBps          = $Snapshot.TxKB
        BW_Mbps          = $Snapshot.BwMbps
        Temp_C           = $Snapshot.TempC
        Downgrade        = $Snapshot.Downgrade.Level
        Downgrade_Reason = @($Snapshot.Downgrade.Reasons) -join '; '
        Error            = $errors -join '; '
    }
    if ($pcell) {
        $row.RSRP_dBm = $pcell.RsrpDbm
        $row.RSRQ_dB = $pcell.RsrqDb
        $row.Band = $pcell.Band
        $row.EARFCN = $pcell.Earfcn
        $row.PCI = $pcell.Pci
        $row.CellID = $pcell.CellId
        $row.TAC = $pcell.Tac
        $row.TA = $pcell.Ta
    }
    return $row
}
