# Presentation: builds one screen (frame) as a list of (Text, Color) lines.
# Pure with respect to the console: no cursor / write operations here.
#
# View state: @{ Paused; Fetching; Done; Quit; LastWidth; LastHeight } (owned by the monitor loop)

function New-FrameLine {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Text = "", [string]$Color = "Gray")

    return [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Get-SectionRule([string]$Title, [int]$Width) {
    $head = "-- $Title "
    return $head + ("-" * [math]::Max(0, $Width - $head.Length))
}

function Get-MonitorFrame {
    param($Session, [hashtable]$View, [int]$Width)

    $config = $Session.Config
    $summary = $Session.Summary
    $snapshot = $Session.Snapshot
    $history = $Session.History.ToArray()

    $lines = New-Object System.Collections.Generic.List[object]
    $rule = "=" * $Width

    # Title bar
    $status = if ($View.Done) { "DONE" } elseif ($View.Paused) { "PAUSED" } elseif ($View.Fetching) { "UPDATING" } else { "RUNNING" }
    $countStr = if ($config.Count -eq 0) { "" } else { "/$($config.Count)" }
    $right = "#$($Session.Iteration)$countStr  [$status]"
    $left = " Fibocom L860-GL LTE Signal Monitor"
    $pad = [math]::Max(1, $Width - $left.Length - $right.Length - 1)
    $lines.Add((New-FrameLine ($left + (" " * $pad) + $right) "Cyan"))
    $lines.Add((New-FrameLine $rule "Cyan"))

    # Device
    $lines.Add((New-FrameLine " Model: $($summary.Model)   FW: $($summary.Firmware)"))
    $lines.Add((New-FrameLine " IMEI:  $($summary.Imei)   ICCID: $($summary.SimIccId)   SPN: $($summary.SimSpn)"))
    $lines.Add((New-FrameLine " Radio: $($summary.RadioState)   DataClass: $($summary.DataClass)"))

    # Network
    $lines.Add((New-FrameLine (Get-SectionRule "Network" $Width) "DarkCyan"))
    if ($null -eq $snapshot) {
        $lines.Add((New-FrameLine " Waiting for first sample..." "DarkGray"))
    }
    else {
        $lines.Add((New-FrameLine " $($snapshot.ProviderName) ($($snapshot.ProviderId)) | $($snapshot.DataClass) | APN: $($snapshot.Apn)"))
        $lines.Add((New-FrameLine (" BW: {0} Mbps   RX: {1} KB/s   TX: {2} KB/s   Updated: {3}" -f $snapshot.BwMbps, $snapshot.RxKB, $snapshot.TxKB, $snapshot.Timestamp)))

        # Serving cells
        $lines.Add((New-FrameLine (Get-SectionRule "Serving Cell (LTE)" $Width) "DarkCyan"))
        if ($snapshot.Serving.Count -eq 0) {
            $lines.Add((New-FrameLine " (no LTE serving cell)" "DarkGray"))
        }
        foreach ($c in $snapshot.Serving) {
            $color = Get-QualityColor $c.Quality
            $bar = Get-RsrpBar $c.RsrpDbm
            $lines.Add((New-FrameLine " $bar RSRP: $($c.RsrpDbm) dBm  RSRQ: $($c.RsrqDb) dB  [$($c.Quality)]" $color))
            $lines.Add((New-FrameLine " $($c.Band) | EARFCN:$($c.Earfcn) | PCI:$($c.Pci) | CellID:$($c.CellId) | TAC:$($c.Tac) | TA:$($c.Ta) | MNC:$($c.Provider)"))
        }

        # RSRP history (primary serving cell)
        $stat = Get-RsrpStatistic $history
        if ($null -ne $stat) {
            $label = " History "
            $spark = Get-RsrpSparkline $history ([math]::Max(10, $Width - $label.Length - 4))
            $lines.Add((New-FrameLine ("$label|$spark|") "DarkGreen"))
            $lines.Add((New-FrameLine ("          min {0} / avg {1} / max {2} dBm  (n={3}, scale -120..-70 dBm: _ . - ~ = + * #)" -f $stat.Min, $stat.Avg, $stat.Max, $stat.Count) "DarkGray"))
        }

        # Neighbors
        $lines.Add((New-FrameLine (Get-SectionRule "Neighbors ($($snapshot.Neighbors.Count))" $Width) "DarkCyan"))
        if ($snapshot.Neighbors.Count -eq 0) {
            $lines.Add((New-FrameLine " (none)" "DarkGray"))
        }
        foreach ($n in ($snapshot.Neighbors | Sort-Object RsrpDbm -Descending)) {
            $nBar = Get-RsrpBar $n.RsrpDbm
            $lines.Add((New-FrameLine (" {0} {1,4} dBm {2,5} dB  {3,-10} EARFCN:{4,-6} PCI:{5}" -f $nBar, $n.RsrpDbm, $n.RsrqDb, $n.Band, $n.Earfcn, $n.Pci) "Gray"))
        }

        # UMTS
        foreach ($u in $snapshot.Umts) {
            $lines.Add((New-FrameLine " [UMTS] CellId:$($u.CellId) UARFCN:$($u.Uarfcn) RSCP:$($u.RscpDbm)dBm" "DarkYellow"))
        }

        if ($snapshot.Error) {
            $lines.Add((New-FrameLine " Error: $($snapshot.Error)" "Red"))
        }
    }

    # Footer is returned separately so it can be pinned to the bottom row.
    $csvStr = if ($config.CsvPath) { "  CSV: $($config.CsvPath)" } else { "" }
    $footer = New-FrameLine " [q] Quit  [p] Pause  [r] Refresh   Interval: $($config.Interval)s$csvStr" "Black"

    return [pscustomobject]@{ Body = $lines; Footer = $footer }
}
