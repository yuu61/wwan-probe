# Presentation: builds one screen (frame) as a list of (Text, Color) lines.
# Pure with respect to the console: no cursor / write operations here.
#
# View state: @{ Paused; Fetching; Done; Quit; Unicode; LastWidth; LastHeight; ChartVisible; ChartRows } (owned by the monitor loop)
# Unicode = console accepts non-ASCII glyphs (TUI switches to UTF-8; plain output does not).
# ChartVisible = @{ <chart Key> = $true/$false } (New-ChartVisibility); $null = defaults.
# ChartRows = sparkline height in rows for Unicode charts ($script:ChartRowsMin..Max); $null = default.

function New-FrameLine {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$Text = '', [string]$Color = 'Gray')

    return [pscustomobject]@{ Text = $Text; Color = $Color }
}

function Get-SectionRule([string]$Title, [int]$Width) {
    $head = "-- $Title "
    return $head + ('-' * [math]::Max(0, $Width - $head.Length))
}

function Format-OptionalValue($Value, [string]$Format) {
    if ($null -eq $Value) { return 'n/a' }
    return ($Format -f $Value)
}

# $Ca: @{ Cells; BandwidthsMHz } from +XLEC
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

# History charts in display order. Key = toggle key in the TUI, History = Session.History name.
# Scale: @{ Step; MinSpan; Floor; Ceiling } for Get-AutoScale, or @{ Log; Floor } for
# Get-LogScale. StepUnit = unit of a value difference (dBm differences are dB).
# ValueFactor (optional) converts the history values into Unit; Si = format values with
# SI prefixes (Format-SiValue).
$script:HistoryCharts = @(
    [pscustomobject]@{ Key = '1'; Label = 'RSRP'; History = 'Rsrp'; Unit = 'dBm'; StepUnit = 'dB'; Color = 'DarkGreen'; Visible = $true
        Scale = @{ Step = 5; MinSpan = 10; Floor = -140; Ceiling = -44 }
    }
    [pscustomobject]@{ Key = '2'; Label = 'RSRQ'; History = 'Rsrq'; Unit = 'dB'; StepUnit = 'dB'; Color = 'DarkYellow'; Visible = $true
        Scale = @{ Step = 1; MinSpan = 4; Floor = -20; Ceiling = -3 }
    }
    [pscustomobject]@{ Key = '3'; Label = 'SNR'; History = 'Rssnr'; Unit = 'dB'; StepUnit = 'dB'; Color = 'DarkCyan'; Visible = $true
        Scale = @{ Step = 5; MinSpan = 10; Floor = -50; Ceiling = 50 }
    }
    [pscustomobject]@{ Key = '4'; Label = 'RX'; History = 'RxKB'; Unit = 'B/s'; StepUnit = 'B/s'; Color = 'DarkMagenta'; Visible = $false
        ValueFactor = 1024; Si = $true; Scale = @{ Log = $true; Floor = 100 }
    }
    [pscustomobject]@{ Key = '5'; Label = 'TX'; History = 'TxKB'; Unit = 'B/s'; StepUnit = 'B/s'; Color = 'Magenta'; Visible = $false
        ValueFactor = 1024; Si = $true; Scale = @{ Log = $true; Floor = 100 }
    }
    [pscustomobject]@{ Key = '6'; Label = 'Temp'; History = 'TempC'; Unit = 'C'; StepUnit = 'C'; Color = 'DarkRed'; Visible = $false
        Scale = @{ Step = 5; MinSpan = 10; Floor = -40; Ceiling = 125 }; RowsRatio = 0.5
    }
)

# Rows for one chart: RowsRatio (default 1) of the shared chart height, rounded down, at least ChartRowsMin.
function Get-ChartRow($Chart, [int]$Rows) {
    $ratio = if ($null -ne $Chart.RowsRatio) { $Chart.RowsRatio } else { 1 }
    return [math]::Max($script:ChartRowsMin, [int][math]::Floor($Rows * $ratio))
}

# Unicode chart height in rows (each row adds 8 levels).
$script:ChartRowsDefault = 2
$script:ChartRowsMin = 1
$script:ChartRowsMax = 10

# Returns $Rows + $Delta clamped into [ChartRowsMin, ChartRowsMax].
function Step-ChartHeight([int]$Rows, [int]$Delta) {
    return [math]::Max($script:ChartRowsMin, [math]::Min($script:ChartRowsMax, $Rows + $Delta))
}

# Initial chart visibility: @{ <Key> = $true/$false }.
function New-ChartVisibility {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    $visible = @{}
    foreach ($c in $script:HistoryCharts) { $visible[$c.Key] = $c.Visible }
    return $visible
}

# Toggles one chart ($Key = '1'..) or, with $Key = 'all', hides every chart when any
# is shown and shows every chart otherwise. Returns $false for an unknown key.
function Switch-ChartVisibility([hashtable]$Visible, [string]$Key) {
    if ($Key -eq 'all') {
        $show = -not ($Visible.Values -contains $true)
        foreach ($k in @($Visible.Keys)) { $Visible[$k] = $show }
        return $true
    }
    if (-not $Visible.ContainsKey($Key)) { return $false }
    $Visible[$Key] = -not $Visible[$Key]
    return $true
}

# Axis label that fits 5 columns: 10000 and above as "10k".
function Format-AxisValue([double]$Value) {
    if ([math]::Abs($Value) -ge 10000) { return '{0:0}k' -f ($Value / 1000) }
    return '{0:0.##}' -f $Value
}

# Value with an SI prefix (k/M/G, 1000 steps) and at most 3 significant digits:
# 1234 'B/s' -> "1.23 kB/s". Without $Unit it fits 5 columns for axis labels: "1.23k".
function Format-SiValue([double]$Value, [string]$Unit = '') {
    $prefixes = '', 'k', 'M', 'G'
    $i = 0
    while ($i -lt $prefixes.Count - 1 -and [math]::Abs($Value) -ge 999.5 * [math]::Pow(1000, $i)) { $i++ }
    $scaled = $Value / [math]::Pow(1000, $i)
    $format = if ([math]::Abs($scaled) -lt 10) { '{0:0.##}' } elseif ([math]::Abs($scaled) -lt 100) { '{0:0.#}' } else { '{0:0}' }
    if ($Unit) { return ($format -f $scaled) + ' ' + $prefixes[$i] + $Unit }
    return ($format -f $scaled) + $prefixes[$i]
}

# Appends one history chart (sparkline rows + stats line) to $Lines.
# The scale is computed from the visible (most recent) samples only; its bounds are
# shown as the axis labels. Stats cover the whole history.
function Add-HistoryChart {
    param(
        [System.Collections.Generic.List[object]]$Lines, $Chart, [double[]]$Values,
        [int]$Width, [bool]$Unicode, [int]$Rows = $script:ChartRowsDefault
    )
    $headWidth = 12
    $sparkWidth = [math]::Max(10, $Width - $headWidth - 4)
    if ($Chart.ValueFactor) { $Values = [double[]]@($Values | ForEach-Object { $_ * $Chart.ValueFactor }) }
    $visible = @($Values | Select-Object -Last $sparkWidth)
    $scale = $Chart.Scale
    $range = if ($scale.Log) { Get-LogScale -Values $visible -Floor $scale.Floor } else { Get-AutoScale -Values $visible @scale }
    $maxText = if ($Chart.Si) { Format-SiValue $range.Max } else { Format-AxisValue $range.Max }
    $minText = if ($Chart.Si) { Format-SiValue $range.Min } else { Format-AxisValue $range.Min }
    # Log charts plot log10(v); the axis labels keep the original values.
    $plot = [pscustomobject]@{ Values = $visible; Min = $range.Min; Max = $range.Max }
    if ($scale.Log) {
        $plot = [pscustomobject]@{ Values = (ConvertTo-LogValue $visible $range.Min); Min = [math]::Log10($range.Min); Max = [math]::Log10($range.Max) }
    }
    if ($Unicode) {
        $sparkRows = @(Get-BlockSparkline $plot.Values $plot.Min $plot.Max $sparkWidth $Rows)
        $last = $sparkRows.Count - 1
        for ($r = 0; $r -le $last; $r++) {
            # Axis labels: max on the top row, min on the bottom row (a single row shows only the label).
            $axis = if ($last -eq 0) { '' } elseif ($r -eq 0) { $maxText } elseif ($r -eq $last) { $minText } else { '' }
            $label = if ($r -eq 0) { $Chart.Label } else { '' }
            $Lines.Add((New-FrameLine ((' {0,-5}{1,5} |{2}|' -f $label, $axis, $sparkRows[$r])) $Chart.Color))
        }
        $scaleText = if ($scale.Log) { 'log, {0:0.#} levels/decade' -f (8 * $sparkRows.Count / ($plot.Max - $plot.Min)) }
        else { '{0:0.##} {1}/level' -f (($range.Max - $range.Min) / (8 * $sparkRows.Count)), $Chart.StepUnit }
        if ($last -eq 0) { $scaleText = 'scale {0}..{1} {2}, {3}' -f $minText, $maxText, $Chart.Unit, $scaleText }
    }
    else {
        $Lines.Add((New-FrameLine ((' {0,-10} |{1}|' -f $Chart.Label, (Get-Sparkline $plot.Values $plot.Min $plot.Max $sparkWidth))) $Chart.Color))
        $scaleText = '{0} {1}..{2} {3}: _ . - ~ = + * #' -f $(if ($scale.Log) { 'log scale' } else { 'scale' }), $minText, $maxText, $Chart.Unit
    }
    $stat = Get-SignalStatistic $Values
    $text = if ($null -eq $stat) { '(no valid samples)' }
    elseif ($Chart.Si) {
        'min {0} / avg {1} / max {2}  (n={3}, {4})' -f (Format-SiValue $stat.Min $Chart.Unit), (Format-SiValue $stat.Avg $Chart.Unit),
        (Format-SiValue $stat.Max $Chart.Unit), $stat.Count, $scaleText
    }
    else {
        'min {0} / avg {1} / max {2} {3}  (n={4}, {5})' -f $stat.Min, $stat.Avg, $stat.Max, $Chart.Unit, $stat.Count, $scaleText
    }
    $Lines.Add((New-FrameLine ((' ' * ($headWidth + 1)) + $text) 'DarkGray'))
}

# History section: the visible charts on one time axis; hidden ones are listed in the title.
function Add-HistorySection {
    param([System.Collections.Generic.List[object]]$Lines, $Session, [hashtable]$View, [int]$Width)

    $visibility = if ($View.ChartVisible) { $View.ChartVisible } else { New-ChartVisibility }
    $chartRows = if ($View.ChartRows) { $View.ChartRows } else { $script:ChartRowsDefault }
    $shown = @($script:HistoryCharts | Where-Object { $visibility[$_.Key] })
    $hidden = @($script:HistoryCharts | Where-Object { -not $visibility[$_.Key] })
    $title = 'History (primary cell)'
    if ($hidden.Count -gt 0) { $title += '  hidden: ' + (($hidden | ForEach-Object { "$($_.Key) $($_.Label)" }) -join ', ') }
    $Lines.Add((New-FrameLine (Get-SectionRule $title $Width) 'DarkCyan'))
    foreach ($chart in $shown) {
        Add-HistoryChart -Lines $Lines -Chart $chart -Values $Session.History[$chart.History].ToArray() -Width $Width -Unicode $View.Unicode -Rows (Get-ChartRow $chart $chartRows)
    }
}

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
        $Lines.Add((New-FrameLine ' (no LTE cell changes observed this session)' 'DarkGray'))
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
    $left = ' Fibocom L860-GL LTE Signal Monitor'
    $pad = [math]::Max(1, $Width - $left.Length - $right.Length - 1)
    $lines.Add((New-FrameLine ($left + (' ' * $pad) + $right) 'Cyan'))
    $lines.Add((New-FrameLine $rule 'Cyan'))

    # 2G/3G downgrade warnings go first so they are never scrolled away
    Add-DowngradeLine -Lines $lines -Finding $(if ($snapshot) { $snapshot.Downgrade }) -Log $Session.DowngradeLog

    if ($View.HandoverVisible) {
        Add-HandoverSection -Lines $lines -Log $Session.HandoverLog -View $View -Width $Width
        return [pscustomobject]@{
            Body   = $lines
            Footer = New-FrameLine ' [h] Monitor  [Up/Down] Newer/Older  [q] Quit  [p] Pause  [r] Refresh' 'Black'
        }
    }

    # Device
    $lines.Add((New-FrameLine " Model: $($summary.Model)   FW: $($summary.Firmware)"))
    $lines.Add((New-FrameLine " IMEI:  $($summary.Imei)   ICCID: $($summary.SimIccId)   SPN: $($summary.SimSpn)"))
    $lines.Add((New-FrameLine " Radio: $($summary.RadioState)   DataClass: $($summary.DataClass)"))
    $rat = $summary.RatConfig
    if ($null -eq $rat) {
        $lines.Add((New-FrameLine ' RAT: n/a   LTE bands: n/a' 'DarkGray'))
    }
    else {
        $legacyBands = @($rat.GsmBands | ForEach-Object { "$_" }) + @($rat.UmtsBands | ForEach-Object { "B$_" })
        $legacyAllowed = $rat.Allowed -match '2G|3G'
        $ratText = " RAT: $($rat.Allowed) (prefer $($rat.Preferred))"
        if ($legacyAllowed) { $ratText += "   2G/3G bands: $($legacyBands -join ' ')   [2G/3G enabled: downgrade possible]" }
        $lines.Add((New-FrameLine $ratText $(if ($legacyAllowed) { 'DarkYellow' } else { 'DarkGray' })))
        $lines.Add((New-FrameLine (' LTE bands: ' + (($rat.LteBands | ForEach-Object { "B$_" }) -join ' ')) 'DarkGray'))
    }

    # Network
    $lines.Add((New-FrameLine (Get-SectionRule 'Network' $Width) 'DarkCyan'))
    if ($null -eq $snapshot) {
        $lines.Add((New-FrameLine ' Waiting for first sample...' 'DarkGray'))
    }
    else {
        $lines.Add((New-FrameLine " $($snapshot.ProviderName) ($($snapshot.ProviderId)) | $($snapshot.DataClass) | APN: $($snapshot.Apn)"))
        $lines.Add((New-FrameLine (' BW: {0} Mbps   RX: {1}   TX: {2}   Updated: {3}' -f $snapshot.BwMbps,
                    (Format-SiValue ($snapshot.RxKB * 1024) 'B/s'), (Format-SiValue ($snapshot.TxKB * 1024) 'B/s'), $snapshot.Timestamp)))
        $lines.Add((New-FrameLine (' Temp: {0}   RSSNR: {1}   CA: {2}' -f
                    (Format-OptionalValue $snapshot.TempC '{0} C'), (Format-OptionalValue $snapshot.Rssnr '{0:0.0} dB'),
                    (Format-CarrierAggregation $snapshot.Ca))))

        # Serving cells
        $lines.Add((New-FrameLine (Get-SectionRule 'Serving Cell (LTE)' $Width) 'DarkCyan'))
        if ($snapshot.Serving.Count -eq 0) {
            $lines.Add((New-FrameLine ' (no LTE serving cell)' 'DarkGray'))
        }
        foreach ($c in $snapshot.Serving) {
            $color = Get-QualityColor $c.Quality
            $bar = Get-RsrpBar $c.RsrpDbm
            $lines.Add((New-FrameLine " $bar RSRP: $($c.RsrpDbm) dBm  RSRQ: $($c.RsrqDb) dB  [$($c.Quality)]" $color))
            $lines.Add((New-FrameLine " $($c.Band) | EARFCN:$($c.Earfcn) | PCI:$($c.Pci) | CellID:$($c.CellId) | TAC:$($c.Tac) | TA:$($c.Ta) | MNC:$($c.Provider)"))
        }

        Add-HandoverSection -Lines $lines -Log $Session.HandoverLog -View $View -Width $Width

        # History (primary serving cell and modem-wide values) on one time axis
        if ($Session.History['Rsrp'].Count -gt 0) {
            Add-HistorySection -Lines $lines -Session $Session -View $View -Width $Width
        }

        # Neighbors (AT+XMCI via the Intel AT Tunnel service)
        if ($null -eq $snapshot.Neighbors) {
            $lines.Add((New-FrameLine (Get-SectionRule 'Neighbors' $Width) 'DarkCyan'))
            $reason = if ($snapshot.AtError) { $snapshot.AtError } else { 'AT+XMCI failed' }
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
    $footer = New-FrameLine " [q] Quit  [p] Pause  [r] Refresh  [h] Handovers  [1-6] Chart  [g] All charts  [Up/Down] Chart rows   Interval: $($config.Interval)s$csvStr" 'Black'

    return [pscustomobject]@{ Body = $lines; Footer = $footer }
}
