# Presentation: handover history section (compact on the main screen, paged in the [h] view).

function Format-HandoverCell($Cell) {
    return '{0} PCI:{1} PLMN:{2} EARFCN:{3} TAC:{4} RSRP:{5}' -f
    $Cell.Band, $Cell.Pci, $Cell.Provider, $Cell.Earfcn, $Cell.Tac,
    (Format-OptionalValue $Cell.RsrpDbm '{0}dBm')
}

# Compact recent changes on the main screen; a separate view keeps the retained
# history accessible even when charts or a small console would clip the body.
function Add-HandoverSection {
    param([System.Collections.Generic.List[object]]$Lines, $Log, [hashtable]$View, [int]$Width)

    $count = if ($Log) { $Log.Count } else { 0 }
    $Lines.Add((New-FrameLine (Get-SectionRule "Handover history ($count) [h]" $Width) 'DarkCyan'))
    if ($null -eq $Log -or $Log.Entries.Count -eq 0) {
        $Lines.Add((New-FrameLine ' (no LTE cell changes observed since start or reset)' 'DarkGray'))
        return
    }
    if ($View.HandoverVisible) {
        $height = if ($View.LastHeight -gt 0) { $View.LastHeight } else { 30 }
        # Title, rule, optional downgrade warning, section title, range and footer.
        $pageSize = [math]::Max(1, [int][math]::Floor(($height - 6) / 2))
        $offset = [math]::Clamp([int]$View.HandoverOffset, 0, [math]::Max(0, $Log.Entries.Count - $pageSize))
        $View.HandoverOffset = $offset
        $end = [math]::Min($Log.Entries.Count, $offset + $pageSize)
        $Lines.Add((New-FrameLine (' Newest first: {0}-{1} / {2} retained (limit {3})' -f ($offset + 1), $end, $Log.Entries.Count, $Log.MaxEntries) 'DarkGray'))
        for ($i = $offset; $i -lt $end; $i++) {
            $entry = $Log.Entries[$Log.Entries.Count - 1 - $i]
            $Lines.Add((New-FrameLine " #$($entry.Number) $($entry.Timestamp) Switched to CellID:$($entry.To.CellId)" 'Yellow'))
            $Lines.Add((New-FrameLine ('   ' + (Format-HandoverCell $entry.To))))
        }
    }
    else {
        for ($i = $Log.Entries.Count - 1; $i -ge [math]::Max(0, $Log.Entries.Count - 3); $i--) {
            $entry = $Log.Entries[$i]
            $Lines.Add((New-FrameLine (' {0} Switched to CellID:{1} {2} PCI:{3}' -f
                        $entry.Timestamp, $entry.To.CellId, $entry.To.Band, $entry.To.Pci) 'Yellow'))
        }
    }
}
