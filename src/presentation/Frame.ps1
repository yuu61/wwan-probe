# Presentation: builds one screen (frame) as a list of (Text, Color) lines.
# Pure with respect to the console: no cursor / write operations here.
#
# View state: @{ Paused; Fetching; Done; Quit; Unicode; LastWidth; LastHeight } (owned by the monitor loop)
# Unicode = console accepts non-ASCII glyphs (TUI switches to UTF-8; plain output does not).

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

function Format-OptionalValue($Value, [string]$Format) {
    if ($null -eq $Value) { return "n/a" }
    return ($Format -f $Value)
}

# $Ca: @{ Cells; BandwidthsMHz } from +XLEC
function Format-CarrierAggregation($Ca) {
    if ($null -eq $Ca) { return "n/a" }
    if ($Ca.Cells -eq 0) { return "not on LTE" }
    $bw = ($Ca.BandwidthsMHz | ForEach-Object { if ($null -eq $_) { "?" } else { "$_" } }) -join "+"
    $cells = if ($Ca.Cells -eq 1) { "1 cell" } else { "$($Ca.Cells) cells" }
    return "$cells ($bw MHz)"
}

# $Finding: current sample (Get-DowngradeFinding), $Log: Session.DowngradeLog
function Add-DowngradeLine([System.Collections.Generic.List[object]]$Lines, $Finding, $Log) {
    if ($Finding -and $Finding.Level -eq 'Alert') {
        $Lines.Add((New-FrameLine (" !! 2G/3G DOWNGRADE: " + ($Finding.Reasons -join "; ")) "Red"))
    }
    elseif ($Finding -and $Finding.Level -eq 'Warning') {
        $Lines.Add((New-FrameLine (" !  2G/3G cells visible: " + ($Finding.Reasons -join "; ")) "Yellow"))
    }
    if ($Log -and ($Log.AlertCount + $Log.WarningCount) -gt 0 -and -not ($Finding -and $Finding.Level -ne 'None')) {
        $text = " !  2G/3G seen earlier (alert {0} / warning {1} samples), last {2} [{3}]: {4}" -f
            $Log.AlertCount, $Log.WarningCount, $Log.Last, $Log.LastLevel, ($Log.LastReasons -join "; ")
        $Lines.Add((New-FrameLine $text "DarkYellow"))
    }
}

# Appends one history chart (sparkline rows + stats line) to $Lines.
# $Scale: @{ Step; MinSpan; Floor; Ceiling } for Get-AutoScale. The scale is computed
# from the visible (most recent) samples only; its bounds are shown as the axis labels.
# Stats cover the whole history.
function Add-HistoryChart {
    param(
        [System.Collections.Generic.List[object]]$Lines, [string]$Label, [double[]]$Values,
        [hashtable]$Scale, [string]$Unit, [string]$Color, [int]$Width, [bool]$Unicode
    )
    $headWidth = 12
    $sparkWidth = [math]::Max(10, $Width - $headWidth - 4)
    $visible = @($Values | Select-Object -Last $sparkWidth)
    $range = Get-AutoScale -Values $visible @Scale
    if ($Unicode) {
        $rows = Get-BlockSparkline $visible $range.Min $range.Max $sparkWidth
        $Lines.Add((New-FrameLine ((" {0,-5}{1,5} |{2}|" -f $Label, $range.Max, $rows[0])) $Color))
        $Lines.Add((New-FrameLine ((" {0,-5}{1,5} |{2}|" -f "", $range.Min, $rows[1])) $Color))
        # Step is a difference, so it is always in dB (not dBm).
        $scaleText = "{0:0.##} dB/level" -f (($range.Max - $range.Min) / 16)
    }
    else {
        $Lines.Add((New-FrameLine ((" {0,-10} |{1}|" -f $Label, (Get-Sparkline $visible $range.Min $range.Max $sparkWidth))) $Color))
        $scaleText = "scale {0}..{1} {2}: _ . - ~ = + * #" -f $range.Min, $range.Max, $Unit
    }
    $stat = Get-SignalStatistic $Values
    $text = if ($null -eq $stat) { "(no valid samples)" } else {
        "min {0} / avg {1} / max {2} {3}  (n={4}, {5})" -f $stat.Min, $stat.Avg, $stat.Max, $Unit, $stat.Count, $scaleText
    }
    $Lines.Add((New-FrameLine ((" " * ($headWidth + 1)) + $text) "DarkGray"))
}

function Get-MonitorFrame {
    param($Session, [hashtable]$View, [int]$Width)

    $config = $Session.Config
    $summary = $Session.Summary
    $snapshot = $Session.Snapshot

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

    # 2G/3G downgrade warnings go first so they are never scrolled away
    Add-DowngradeLine -Lines $lines -Finding $(if ($snapshot) { $snapshot.Downgrade }) -Log $Session.DowngradeLog

    # Device
    $lines.Add((New-FrameLine " Model: $($summary.Model)   FW: $($summary.Firmware)"))
    $lines.Add((New-FrameLine " IMEI:  $($summary.Imei)   ICCID: $($summary.SimIccId)   SPN: $($summary.SimSpn)"))
    $lines.Add((New-FrameLine " Radio: $($summary.RadioState)   DataClass: $($summary.DataClass)"))
    $rat = $summary.RatConfig
    if ($null -eq $rat) {
        $lines.Add((New-FrameLine " RAT: n/a   LTE bands: n/a" "DarkGray"))
    }
    else {
        $legacyBands = @($rat.GsmBands | ForEach-Object { "$_" }) + @($rat.UmtsBands | ForEach-Object { "B$_" })
        $legacyAllowed = $rat.Allowed -match '2G|3G'
        $ratText = " RAT: $($rat.Allowed) (prefer $($rat.Preferred))"
        if ($legacyAllowed) { $ratText += "   2G/3G bands: $($legacyBands -join ' ')   [2G/3G enabled: downgrade possible]" }
        $lines.Add((New-FrameLine $ratText $(if ($legacyAllowed) { "DarkYellow" } else { "DarkGray" })))
        $lines.Add((New-FrameLine (" LTE bands: " + (($rat.LteBands | ForEach-Object { "B$_" }) -join " ")) "DarkGray"))
    }

    # Network
    $lines.Add((New-FrameLine (Get-SectionRule "Network" $Width) "DarkCyan"))
    if ($null -eq $snapshot) {
        $lines.Add((New-FrameLine " Waiting for first sample..." "DarkGray"))
    }
    else {
        $lines.Add((New-FrameLine " $($snapshot.ProviderName) ($($snapshot.ProviderId)) | $($snapshot.DataClass) | APN: $($snapshot.Apn)"))
        $lines.Add((New-FrameLine (" BW: {0} Mbps   RX: {1} KB/s   TX: {2} KB/s   Updated: {3}" -f $snapshot.BwMbps, $snapshot.RxKB, $snapshot.TxKB, $snapshot.Timestamp)))
        $lines.Add((New-FrameLine (" Temp: {0}   RSSNR: {1}   CA: {2}" -f
            (Format-OptionalValue $snapshot.TempC "{0} C"), (Format-OptionalValue $snapshot.Rssnr "{0:0.0} dB"),
            (Format-CarrierAggregation $snapshot.Ca))))

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

        # History (primary serving cell), RSRP and RSRQ on the same time axis
        $rsrp = $Session.RsrpHistory.ToArray()
        if ($rsrp.Count -gt 0) {
            $lines.Add((New-FrameLine (Get-SectionRule "History (primary cell)" $Width) "DarkCyan"))
            Add-HistoryChart -Lines $lines -Label "RSRP" -Values $rsrp -Unit "dBm" `
                -Scale @{ Step = 5; MinSpan = 10; Floor = -140; Ceiling = -44 } -Color "DarkGreen" -Width $Width -Unicode $View.Unicode
            Add-HistoryChart -Lines $lines -Label "RSRQ" -Values $Session.RsrqHistory.ToArray() -Unit "dB" `
                -Scale @{ Step = 1; MinSpan = 4; Floor = -20; Ceiling = -3 } -Color "DarkYellow" -Width $Width -Unicode $View.Unicode
        }

        # Neighbors (AT+XMCI via the Intel AT Tunnel service)
        if ($null -eq $snapshot.Neighbors) {
            $lines.Add((New-FrameLine (Get-SectionRule "Neighbors" $Width) "DarkCyan"))
            $reason = if ($snapshot.AtError) { $snapshot.AtError } else { "AT+XMCI failed" }
            $lines.Add((New-FrameLine " (unavailable: $reason)" "DarkGray"))
        }
        else {
            $lines.Add((New-FrameLine (Get-SectionRule "Neighbors ($($snapshot.Neighbors.Count))" $Width) "DarkCyan"))
            if ($snapshot.Neighbors.Count -eq 0) {
                $lines.Add((New-FrameLine " (none)" "DarkGray"))
            }
            foreach ($n in ($snapshot.Neighbors | Sort-Object RsrpDbm -Descending)) {
                $nBar = Get-RsrpBar $n.RsrpDbm
                $lines.Add((New-FrameLine (" {0} {1,4} dBm {2,5} dB  {3,-10} EARFCN:{4,-6} PCI:{5}" -f $nBar, $n.RsrpDbm, $n.RsrqDb, $n.Band, $n.Earfcn, $n.Pci) "Gray"))
            }
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
