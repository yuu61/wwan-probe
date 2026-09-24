# Application: snapshot -> CSV logging (column order is part of the output contract).

$script:CsvHeader = "Timestamp,RSRP_dBm,RSRP_idx,RSRQ_dB,RSRQ_idx,Quality,Band,EARFCN,PCI,CellID,TAC,TA,Provider,DataClass,RX_KBps,TX_KBps,BW_Mbps"

function Initialize-SnapshotLog([string]$Path) {
    Initialize-CsvFile -Path $Path -Header $script:CsvHeader
}

function Add-SnapshotLog([string]$Path, $Snapshot) {
    foreach ($c in $Snapshot.Serving) {
        $line = "$($Snapshot.Timestamp),$($c.RsrpDbm),$($c.RsrpIdx),$($c.RsrqDb),$($c.RsrqIdx),$($c.Quality),$($c.Band),$($c.Earfcn),$($c.Pci),$($c.CellId),$($c.Tac),$($c.Ta),$($c.Provider),$($Snapshot.DataClass),$($Snapshot.RxKB),$($Snapshot.TxKB),$($Snapshot.BwMbps)"
        Add-CsvLine -Path $Path -Line $line
    }
}
