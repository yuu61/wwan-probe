# Presentation: builds one screen as Text/Color lines with optional colored Segments.
# Pure with respect to the console: no cursor / write operations here.
# Sections with their own state or tables are in HistoryChart.ps1, HandoverSection.ps1 and
# GnssSection.ps1; they build lines with New-FrameLine / Get-SectionRule from this file.
#
# View state: @{ Paused; Fetching; Done; Quit; Unicode; LastWidth; LastHeight; ChartVisible; ChartRows;
#   HandoverVisible; HandoverOffset; SatelliteVisible; SatelliteOffset } (owned by the monitor loop)
# HandoverVisible / SatelliteVisible = the [h] / [s] view replaces the monitor body (at most one is set);
# the offsets are the first shown row there.
# Unicode = console accepts non-ASCII glyphs (TUI switches to UTF-8; plain output does not).
# ChartVisible = @{ <chart Key> = $true/$false } (New-ChartVisibility); $null = defaults.
# ChartRows = sparkline height in rows for Unicode charts ($script:ChartRowsMin..Max); $null = default.

function New-FrameLine {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Text = '', [string]$Color = 'Gray', [object[]]$Segments = @(), [Nullable[byte]]$GrayLevel = $null)

    if ($Segments.Count -gt 0) { $Text = ($Segments.Text -join '') }
    return [pscustomobject]@{ Text = $Text; Color = $Color; Segments = $Segments; GrayLevel = $GrayLevel }
}

# Count currently observed LTE cells, not historical samples or physical sites.
# EARFCN + PCI identifies duplicate observations across serving/neighbor lists.
function Get-LteBandLine($Rat, $Snapshot) {
    $counts = @{}
    $seen = @{}
    foreach ($cell in (@($Snapshot.Serving) + @($Snapshot.Neighbors))) {
        if ($null -eq $cell -or $cell.Band -notmatch '^B(\d+)(?:/|$)') { continue }
        $band = $Matches[1]
        if ($null -ne $cell.Earfcn -and $null -ne $cell.Pci) {
            $key = '{0}:{1}:{2}' -f $band, $cell.Earfcn, $cell.Pci
            if ($seen.ContainsKey($key)) { continue }
            $seen[$key] = $true
        }
        $counts[$band] = 1 + $counts[$band]
    }

    # Stretch the observed counts across the grayscale range so 1 vs 2 is visible.
    # Only displayed bands determine the maximum; zero keeps the existing default.
    $maxCount = 1
    foreach ($band in $Rat.LteBands) { $maxCount = [math]::Max($maxCount, [int]$counts["$band"]) }
    $segments = New-Object System.Collections.Generic.List[object]
    $segments.Add((New-FrameLine ' LTE bands: ' 'DarkGray'))
    foreach ($band in $Rat.LteBands) {
        if ($segments.Count -gt 1) { $segments.Add((New-FrameLine ' ' 'DarkGray')) }
        $count = $counts["$band"]
        $grayLevel = $null
        if ($count -gt 0) {
            $grayLevel = if ($maxCount -eq 1) { 255 } else { [byte][math]::Round(144 + 111 * ($count - 1) / ($maxCount - 1)) }
        }
        $segments.Add((New-FrameLine "B$band" 'DarkGray' -GrayLevel $grayLevel))
    }
    if (@($Rat.NrBands).Count -gt 0) {
        $segments.Add((New-FrameLine ('   NR bands: ' + (($Rat.NrBands | ForEach-Object { "n$_" }) -join ' ')) 'DarkGray'))
    }
    return New-FrameLine -Color 'DarkGray' -Segments $segments.ToArray()
}

function Get-SectionRule([string]$Title, [int]$Width) {
    $head = "-- $Title "
    return $head + ('-' * [math]::Max(0, $Width - $head.Length))
}

function Format-OptionalValue($Value, [string]$Format) {
    if ($null -eq $Value) { return 'n/a' }
    return ($Format -f $Value)
}

function Format-TrafficRate($ValueKB) {
    if ($null -eq $ValueKB) { return 'n/a' }
    return Format-SiValue ($ValueKB * 1024) 'B/s'
}

# $Ca: @{ Cells; BandwidthsMHz } (ConvertFrom-AtStatus)
function Format-CarrierAggregation($Ca) {
    if ($null -eq $Ca) { return 'n/a' }
    if ($Ca.Cells -eq 0) { return 'not on LTE' }
    $bw = ($Ca.BandwidthsMHz | ForEach-Object { if ($null -eq $_) { '?' } else { "$_" } }) -join '+'
    $cells = if ($Ca.Cells -eq 1) { '1 cell' } else { "$($Ca.Cells) cells" }
    return "$cells ($bw MHz)"
}

# $Finding: current sample (Get-DowngradeFinding), $Log: Session.DowngradeLog
function Add-DowngradeLine([System.Collections.Generic.List[object]]$Lines, $Finding, $Log) {
    if ($Finding -and $Finding.Level -eq 'Alert') {
        $Lines.Add((New-FrameLine (' !! 2G/3G DOWNGRADE: ' + ($Finding.Reasons -join '; ')) 'Red'))
    }
    elseif ($Finding -and $Finding.Level -eq 'Warning') {
        $Lines.Add((New-FrameLine (' !  2G/3G cells visible: ' + ($Finding.Reasons -join '; ')) 'Yellow'))
    }
    if ($Log -and ($Log.AlertCount + $Log.WarningCount) -gt 0 -and -not ($Finding -and $Finding.Level -ne 'None')) {
        $text = ' !  2G/3G seen earlier (alert {0} / warning {1} samples), last {2} [{3}]: {4}' -f
        $Log.AlertCount, $Log.WarningCount, $Log.Last, $Log.LastLevel, ($Log.LastReasons -join '; ')
        $Lines.Add((New-FrameLine $text 'DarkYellow'))
    }
}

function Get-MonitorFrame {
    param($Session, [hashtable]$View, [int]$Width)

    $config = $Session.Config
    $summary = $Session.Summary
    $snapshot = $Session.Snapshot

    $lines = New-Object System.Collections.Generic.List[object]
    $rule = '=' * $Width

    # Title bar
    $status = if ($View.Done) { 'DONE' } elseif ($View.Paused) { 'PAUSED' } elseif ($View.Fetching) { 'UPDATING' } else { 'RUNNING' }
    $countStr = if ($config.Count -eq 0) { '' } else { "/$($config.Count)" }
    $right = "#$($Session.Iteration)$countStr  [$status]"
    $left = ' wwan-probe LTE Signal Monitor'
    $pad = [math]::Max(1, $Width - $left.Length - $right.Length - 1)
    $lines.Add((New-FrameLine ($left + (' ' * $pad) + $right) 'Cyan'))
    $lines.Add((New-FrameLine $rule 'Cyan'))

    # 2G/3G downgrade warnings go first so they are never scrolled away
    Add-DowngradeLine -Lines $lines -Finding $(if ($snapshot) { $snapshot.Downgrade }) -Log $Session.DowngradeLog

    if ($View.HandoverVisible) {
        Add-HandoverSection -Lines $lines -Log $Session.HandoverLog -View $View -Width $Width
        return [pscustomobject]@{
            Body   = $lines
            Footer = New-FrameLine ' [h] Monitor  [Up/Down] Newer/Older  [q] Quit  [p] Pause  [r] Refresh  [R] Reset stats' 'Black'
        }
    }
    $nmeaEnabled = $null -ne $Session.NmeaReceiver
    if ($View.SatelliteVisible) {
        Add-SatelliteSection -Lines $lines -Satellites $(if ($snapshot) { $snapshot.Satellites }) -Enabled $nmeaEnabled -View $View -Width $Width
        return [pscustomobject]@{
            Body   = $lines
            Footer = New-FrameLine ' [s] Monitor  [Up/Down] Scroll  [q] Quit  [p] Pause  [r] Refresh  [R] Reset stats' 'Black'
        }
    }

    # Device
    $lines.Add((New-FrameLine " Model: $($summary.Model)   FW: $($summary.Firmware)"))
    $lines.Add((New-FrameLine " IMEI:  $($summary.Imei)   ICCID: $($summary.SimIccId)   SPN: $($summary.SimSpn)"))
    $lines.Add((New-FrameLine " Radio: $($summary.RadioState)   DataClass: $($summary.DataClass)"))
    $at = $summary.At
    if ($at -and $at.Profile) {
        $lines.Add((New-FrameLine " AT: $($at.Channel.Name) / $($at.Profile.Name)" 'DarkGray'))
    }
    else {
        $reason = if ($at -and $at.Error) { $at.Error } else { 'not initialized' }
        $lines.Add((New-FrameLine " AT: unavailable ($reason)" 'DarkGray'))
    }
    $rat = $summary.RatConfig
    if ($null -eq $rat) {
        $lines.Add((New-FrameLine ' RAT: n/a   LTE bands: n/a' 'DarkGray'))
    }
    else {
        $legacyBands = @($rat.GsmBands | ForEach-Object { "$_" }) + @($rat.UmtsBands | ForEach-Object { "B$_" })
        $legacyAllowed = $summary.LegacyAllowed
        $ratText = " RAT: $($rat.Allowed)"
        if ($rat.Preferred) { $ratText += " (prefer $($rat.Preferred))" }
        if ($legacyAllowed) { $ratText += "   2G/3G bands: $($legacyBands -join ' ')   [2G/3G enabled: downgrade possible]" }
        $lines.Add((New-FrameLine $ratText $(if ($legacyAllowed) { 'DarkYellow' } else { 'DarkGray' })))
        $lines.Add((Get-LteBandLine -Rat $rat -Snapshot $snapshot))
    }

    # Network
    $lines.Add((New-FrameLine (Get-SectionRule 'Network' $Width) 'DarkCyan'))
    if ($null -eq $snapshot) {
        $lines.Add((New-FrameLine ' Waiting for first sample...' 'DarkGray'))
    }
    else {
        $lines.Add((New-FrameLine " $($snapshot.ProviderName) ($($snapshot.ProviderId)) | $($snapshot.DataClass) | APN: $($snapshot.Apn)"))
        $lines.Add((New-FrameLine (' BW: {0}   RX: {1}   TX: {2}   Updated: {3}' -f (Format-OptionalValue $snapshot.BwMbps '{0} Mbps'),
                    (Format-TrafficRate $snapshot.RxKB), (Format-TrafficRate $snapshot.TxKB), $snapshot.Timestamp)))
        if ($snapshot.TrafficError) { $lines.Add((New-FrameLine " Traffic: $($snapshot.TrafficError)" 'DarkYellow')) }
        $lines.Add((New-FrameLine (' Temp: {0}   RSSNR: {1}   CA: {2}' -f
                    (Format-OptionalValue $snapshot.TempC '{0} C'), (Format-OptionalValue $snapshot.Rssnr '{0:0.0} dB'),
                    (Format-CarrierAggregation $snapshot.Ca))))

        Add-GpsSection -Lines $lines -Gps $snapshot.Gps -Satellites $snapshot.Satellites -Width $Width

        # Serving cells
        $lines.Add((New-FrameLine (Get-SectionRule 'Serving Cell (LTE)' $Width) 'DarkCyan'))
        if ($snapshot.Serving.Count -eq 0) {
            $lines.Add((New-FrameLine ' (no LTE serving cell)' 'DarkGray'))
        }
        foreach ($c in $snapshot.Serving) {
            $color = Get-QualityColor $c.Quality
            $bar = Get-RsrpBar $c.RsrpDbm
            $lines.Add((New-FrameLine (' {0} RSRP: {1}  RSRQ: {2}  [{3}]' -f $bar,
                        (Format-OptionalValue $c.RsrpDbm '{0} dBm'), (Format-OptionalValue $c.RsrqDb '{0} dB'),
                        (Format-OptionalValue $c.Quality '{0}')) $color))
            $lines.Add((New-FrameLine " $($c.Band) | EARFCN:$($c.Earfcn) | PCI:$($c.Pci) | CellID:$($c.CellId) | TAC:$($c.Tac) | TA:$($c.Ta) | MNC:$($c.Provider)"))
        }

        Add-HandoverSection -Lines $lines -Log $Session.HandoverLog -View $View -Width $Width

        # History (primary serving cell and modem-wide values) on one time axis
        if ($Session.History['Rsrp'].Count -gt 0) {
            Add-HistorySection -Lines $lines -Session $Session -View $View -Width $Width
        }

        # Neighbors (AT channel, e.g. AT+XMCI; WinRT when the modem reports them there)
        if ($null -eq $snapshot.Neighbors) {
            $lines.Add((New-FrameLine (Get-SectionRule 'Neighbors' $Width) 'DarkCyan'))
            $reason = if ($snapshot.AtError) { $snapshot.AtError } else { 'neighbor cell query failed' }
            $lines.Add((New-FrameLine " (unavailable: $reason)" 'DarkGray'))
        }
        else {
            $lines.Add((New-FrameLine (Get-SectionRule "Neighbors ($($snapshot.Neighbors.Count))" $Width) 'DarkCyan'))
            if ($snapshot.Neighbors.Count -eq 0) {
                $lines.Add((New-FrameLine ' (none)' 'DarkGray'))
            }
            foreach ($n in ($snapshot.Neighbors | Sort-Object RsrpDbm -Descending)) {
                $nBar = Get-RsrpBar $n.RsrpDbm
                $lines.Add((New-FrameLine (' {0} {1,4} dBm {2,5} dB  {3,-10} EARFCN:{4,-6} PCI:{5}' -f $nBar, $n.RsrpDbm, $n.RsrqDb, $n.Band, $n.Earfcn, $n.Pci) 'Gray'))
            }
        }

        # UMTS
        foreach ($u in $snapshot.Umts) {
            $lines.Add((New-FrameLine " [UMTS] CellId:$($u.CellId) UARFCN:$($u.Uarfcn) RSCP:$($u.RscpDbm)dBm" 'DarkYellow'))
        }

        if ($snapshot.Error) {
            $lines.Add((New-FrameLine " Error: $($snapshot.Error)" 'Red'))
        }
    }

    # Footer is returned separately so it can be pinned to the bottom row.
    $csvStr = if ($config.CsvPath) { "  CSV: $($config.CsvPath)" } else { '' }
    $satelliteKey = if ($nmeaEnabled) { '[s] Satellites  ' } else { '' }
    $footer = New-FrameLine " [q] Quit  [p] Pause  [r] Refresh  [R] Reset  [h] Handovers  $($satelliteKey)[1-6] Chart  [g] All charts  [Up/Down] Chart rows   Interval: $($config.Interval)s$csvStr" 'Black'

    return [pscustomobject]@{ Body = $lines; Footer = $footer }
}
