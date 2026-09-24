# Presentation: builds one screen as Text/Color lines with optional colored Segments.
# Pure with respect to the console: no cursor / write operations here.
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

# $Satellites: Get-NmeaObservation (Status; Error; InView; Used; Systems; NmeaReceived).
function Format-SatelliteSummary($Satellites) {
    switch ($Satellites.Status) {
        'Starting' { return 'Starting (waiting for the elevated NMEA helper)' }
        'Stale' { return 'Stale (the NMEA helper stopped updating)' }
        'Unavailable' { return "Unavailable ($($Satellites.Error))" }
    }
    if (-not $Satellites.NmeaReceived) { return 'waiting for NMEA from the GNSS driver' }
    $systems = @($Satellites.Systems.Keys | ForEach-Object { "$_ $($Satellites.Systems[$_].InView)" }) -join ', '
    if ($systems) { $systems = " ($systems)" }
    return "$($Satellites.InView) in view$systems, $($Satellites.Used) used"
}

# $Fix: the receiver's fix state from NMEA (Nmea.ps1); values not received recently are n/a.
function Add-NmeaFixLine([System.Collections.Generic.List[object]]$Lines, $Fix) {
    if ($null -eq $Fix) { return }
    $status = if ($null -eq $Fix.Valid) { 'n/a' } elseif ($Fix.Valid) { 'valid' } else { 'invalid' }
    $color = if ($Fix.Valid -eq $false -or $Fix.Dimension -eq 'NoFix') { 'DarkYellow' } else { 'Gray' }
    $Lines.Add((New-FrameLine (' Fix (NMEA): {0}   Quality: {1}   Mode: {2} ({3})   Sats used: {4}' -f
                (Format-OptionalValue $Fix.Dimension '{0}'), (Format-OptionalValue $Fix.Quality '{0}'),
                (Format-OptionalValue $Fix.Mode '{0}'), $status, (Format-OptionalValue $Fix.SatellitesUsed '{0}')) $color))
    $Lines.Add((New-FrameLine (' Altitude MSL: {0}   Geoid separation: {1}' -f
                (Format-OptionalValue $Fix.AltitudeMslM '{0:0.0} m'), (Format-OptionalValue $Fix.GeoidSeparationM '{0:0.0} m')) $color))
}

function Add-GpsSection([System.Collections.Generic.List[object]]$Lines, $Gps, $Satellites, [int]$Width) {
    if ($null -eq $Gps -and $null -eq $Satellites) { return }
    $Lines.Add((New-FrameLine (Get-SectionRule 'GPS / GNSS' $Width) 'DarkCyan'))
    if ($Gps.Status -eq 'Fix') {
        $Lines.Add((New-FrameLine (' Lat: {0:F6}   Lon: {1:F6}   Accuracy: {2}' -f
                    $Gps.Latitude, $Gps.Longitude, (Format-OptionalValue $Gps.AccuracyM '{0:0.0} m')) 'Green'))
        $Lines.Add((New-FrameLine (' Alt: {0}   Speed: {1}   Heading: {2}' -f
                    (Format-OptionalValue $Gps.AltitudeM '{0:0.0} m'), (Format-OptionalValue $Gps.SpeedMps '{0:0.0} m/s'),
                    (Format-OptionalValue $Gps.HeadingDeg '{0:0.0} deg'))))
        $Lines.Add((New-FrameLine (' HDOP: {0}   PDOP: {1}   VDOP: {2}' -f (Format-OptionalValue $Gps.Hdop '{0:0.0}'),
                    (Format-OptionalValue $Gps.Pdop '{0:0.0}'), (Format-OptionalValue $Gps.Vdop '{0:0.0}'))))
        $Lines.Add((New-FrameLine " Source: Satellite   Fix UTC: $($Gps.Timestamp)" 'DarkGray'))
    }
    elseif ($null -ne $Gps) {
        $detail = switch ($Gps.Status) {
            'Disabled' { $Gps.Error }
            'Unavailable' { $Gps.Error }
            'Stale' { 'satellite report expired; waiting for a fresh fix' }
            default { if ($Gps.Source) { "waiting for satellite fix; $($Gps.Source) position ignored" } else { 'waiting for satellite fix' } }
        }
        $Lines.Add((New-FrameLine " GPS: $($Gps.Status) ($detail)" 'DarkYellow'))
    }
    if ($null -ne $Satellites) {
        $color = if ($Satellites.Status -eq 'Receiving') { 'Gray' } else { 'DarkYellow' }
        $Lines.Add((New-FrameLine " Satellites: $(Format-SatelliteSummary $Satellites)  [s]" $color))
        if ($Satellites.Status -eq 'Receiving') { Add-NmeaFixLine $Lines $Satellites.Fix }
    }
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

# History charts in display order. Key = toggle key in the TUI, History = Session.History name.
# Scale: @{ Step; MinSpan; Floor; Ceiling } for Get-AutoScale, or @{ Log; Floor } for
# Get-LogScale. StepUnit = unit of a value difference (dBm differences are dB).
# ValueFactor (optional) converts the history values into Unit; Si = format values with
# SI prefixes (Format-SiValue). ScaleGroup (optional): shown charts with the same group
# share one scale computed from all their visible samples (same Scale settings required).
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
        ValueFactor = 1024; Si = $true; Scale = @{ Log = $true; Floor = 100 }; ScaleGroup = 'Throughput'
    }
    [pscustomobject]@{ Key = '5'; Label = 'TX'; History = 'TxKB'; Unit = 'B/s'; StepUnit = 'B/s'; Color = 'Magenta'; Visible = $false
        ValueFactor = 1024; Si = $true; Scale = @{ Log = $true; Floor = 100 }; ScaleGroup = 'Throughput'
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

# Width of a chart row head (label + axis label).
$script:ChartHeadWidth = 12

# Sparkline columns for console $Width.
function Get-SparkWidth([int]$Width) {
    return [math]::Max(10, $Width - $script:ChartHeadWidth - 4)
}

# History values converted into the chart's Unit (ValueFactor).
function ConvertTo-ChartValue($Chart, [double[]]$Values) {
    if (-not $Chart.ValueFactor) { return , $Values }
    return , [double[]]@($Values | ForEach-Object { $_ * $Chart.ValueFactor })
}

# The samples a chart plots at console $Width: the most recent ones, in the chart's Unit.
function Get-ChartWindow($Chart, [double[]]$Values, [int]$Width) {
    return , (ConvertTo-ChartValue $Chart @($Values | Select-Object -Last (Get-SparkWidth $Width)))
}

# Scale range @{ Min; Max } of $Values (in Unit) with the chart's Scale settings.
function Get-ChartScale($Chart, [double[]]$Values) {
    $scale = $Chart.Scale
    if ($scale.Log) { return Get-LogScale -Values $Values -Floor $scale.Floor }
    return Get-AutoScale -Values $Values @scale
}

# Appends one history chart (sparkline rows + stats line) to $Lines.
# The scale is $Range (@{ Min; Max }, shared by a ScaleGroup) or, without it, computed from
# the visible (most recent) samples only; its bounds are shown as the axis labels.
# Stats cover the whole history.
function Add-HistoryChart {
    param(
        [System.Collections.Generic.List[object]]$Lines, $Chart, [double[]]$Values,
        [int]$Width, [bool]$Unicode, [int]$Rows = $script:ChartRowsDefault, $Range = $null
    )
    $sparkWidth = Get-SparkWidth $Width
    $visible = Get-ChartWindow -Chart $Chart -Values $Values -Width $Width
    if ($null -eq $Range) { $Range = Get-ChartScale $Chart $visible }
    $scale = $Chart.Scale
    $maxText = if ($Chart.Si) { Format-SiValue $Range.Max } else { Format-AxisValue $Range.Max }
    $minText = if ($Chart.Si) { Format-SiValue $Range.Min } else { Format-AxisValue $Range.Min }
    # Log charts plot log10(v); the axis labels keep the original values.
    $plot = [pscustomobject]@{ Values = $visible; Min = $Range.Min; Max = $Range.Max }
    if ($scale.Log) {
        $plot = [pscustomobject]@{ Values = (ConvertTo-LogValue $visible $Range.Min); Min = [math]::Log10($Range.Min); Max = [math]::Log10($Range.Max) }
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
        else { '{0:0.##} {1}/level' -f (($Range.Max - $Range.Min) / (8 * $sparkRows.Count)), $Chart.StepUnit }
        if ($last -eq 0) { $scaleText = 'scale {0}..{1} {2}, {3}' -f $minText, $maxText, $Chart.Unit, $scaleText }
    }
    else {
        $Lines.Add((New-FrameLine ((' {0,-10} |{1}|' -f $Chart.Label, (Get-Sparkline $plot.Values $plot.Min $plot.Max $sparkWidth))) $Chart.Color))
        $scaleText = '{0} {1}..{2} {3}: _ . - ~ = + * #' -f $(if ($scale.Log) { 'log scale' } else { 'scale' }), $minText, $maxText, $Chart.Unit
    }
    $stat = Get-SignalStatistic (ConvertTo-ChartValue $Chart $Values)
    $text = if ($null -eq $stat) { '(no valid samples)' }
    elseif ($Chart.Si) {
        'min {0} / avg {1} / max {2}  (n={3}, {4})' -f (Format-SiValue $stat.Min $Chart.Unit), (Format-SiValue $stat.Avg $Chart.Unit),
        (Format-SiValue $stat.Max $Chart.Unit), $stat.Count, $scaleText
    }
    else {
        'min {0} / avg {1} / max {2} {3}  (n={4}, {5})' -f $stat.Min, $stat.Avg, $stat.Max, $Chart.Unit, $stat.Count, $scaleText
    }
    $Lines.Add((New-FrameLine ((' ' * ($script:ChartHeadWidth + 1)) + $text) 'DarkGray'))
}

# History section: the visible charts on one time axis; hidden ones are listed in the title.
# Shown charts with the same ScaleGroup share one scale; a chart shown alone keeps its own.
function Add-HistorySection {
    param([System.Collections.Generic.List[object]]$Lines, $Session, [hashtable]$View, [int]$Width)

    $visibility = if ($View.ChartVisible) { $View.ChartVisible } else { New-ChartVisibility }
    $chartRows = if ($View.ChartRows) { $View.ChartRows } else { $script:ChartRowsDefault }
    $shown = @($script:HistoryCharts | Where-Object { $visibility[$_.Key] })
    $hidden = @($script:HistoryCharts | Where-Object { -not $visibility[$_.Key] })
    $title = 'History (primary cell)'
    if ($hidden.Count -gt 0) { $title += '  hidden: ' + (($hidden | ForEach-Object { "$($_.Key) $($_.Label)" }) -join ', ') }
    $Lines.Add((New-FrameLine (Get-SectionRule $title $Width) 'DarkCyan'))
    $groupRanges = @{}
    foreach ($group in @($shown | Where-Object { $_.ScaleGroup } | Group-Object ScaleGroup | Where-Object { $_.Count -gt 1 })) {
        $samples = New-Object System.Collections.Generic.List[double]
        foreach ($chart in $group.Group) { $samples.AddRange((Get-ChartWindow -Chart $chart -Values $Session.History[$chart.History].ToArray() -Width $Width)) }
        $groupRanges[$group.Name] = Get-ChartScale $group.Group[0] $samples.ToArray()
    }
    foreach ($chart in $shown) {
        $range = if ($chart.ScaleGroup) { $groupRanges[$chart.ScaleGroup] }
        Add-HistoryChart -Lines $Lines -Chart $chart -Values $Session.History[$chart.History].ToArray() -Width $Width -Unicode $View.Unicode -Rows (Get-ChartRow $chart $chartRows) -Range $range
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

$script:SatelliteSystemColors = @{
    GPS = 'Green'; QZSS = 'White'; SBAS = 'Gray'; GLONASS = 'Magenta'
    Galileo = 'Cyan'; BeiDou = 'Yellow'; NavIC = 'DarkMagenta'; Unknown = 'DarkGray'
}

# Satellite list (the [s] view): one row per satellite and signal, colored by constellation.
# $Satellites = $null means -Nmea is off ($Enabled = $false) or no sample has completed yet.
function Add-SatelliteSection {
    param([System.Collections.Generic.List[object]]$Lines, $Satellites, [bool]$Enabled, [hashtable]$View, [int]$Width)

    $Lines.Add((New-FrameLine (Get-SectionRule 'Satellites (NMEA GSV/GSA) [s]' $Width) 'DarkCyan'))
    if (-not $Enabled) {
        $Lines.Add((New-FrameLine ' (satellite list is off: start lte_monitor.ps1 with -Nmea)' 'DarkGray'))
        return
    }
    if ($null -eq $Satellites) {
        $Lines.Add((New-FrameLine ' Waiting for first sample...' 'DarkGray'))
        return
    }
    $summary = Format-SatelliteSummary $Satellites
    if ($Satellites.Status -ne 'Receiving' -or @($Satellites.Satellites).Count -eq 0) {
        $Lines.Add((New-FrameLine " $summary" $(if ($Satellites.Status -eq 'Receiving') { 'DarkGray' } else { 'DarkYellow' })))
        if ($Satellites.Status -eq 'Receiving') { Add-NmeaFixLine $Lines $Satellites.Fix }
        return
    }
    $Lines.Add((New-FrameLine " $summary   Updated: $($Satellites.UpdatedUtc)" 'DarkGray'))
    Add-NmeaFixLine $Lines $Satellites.Fix
    $Lines.Add((New-FrameLine ' System     ID  Sig  Elev  Azim  SNR  Used  C/N0 (0-50 dB-Hz)' 'DarkGray'))
    $rows = @($Satellites.Satellites)
    $height = if ($View.LastHeight -gt 0) { $View.LastHeight } else { 30 }
    # Title, rule, optional downgrade warning, section title, summary, two fix lines, header,
    # scroll line and footer.
    $pageSize = [math]::Max(1, $height - 10)
    $offset = [math]::Clamp([int]$View.SatelliteOffset, 0, [math]::Max(0, $rows.Count - $pageSize))
    $View.SatelliteOffset = $offset
    foreach ($s in ($rows | Select-Object -Skip $offset -First $pageSize)) {
        $text = ' {0,-8} {1,4} {2,4} {3,5} {4,5} {5,4}  {6,-4}  {7}' -f $s.System, $s.Id, $s.Signal,
        (Format-OptionalValue $s.ElevationDeg '{0}'), (Format-OptionalValue $s.AzimuthDeg '{0}'),
        (Format-OptionalValue $s.SnrDbHz '{0}'), $(if ($s.Used) { 'yes' } else { '' }), (Get-SnrBar $s.SnrDbHz)
        $color = $script:SatelliteSystemColors[[string]$s.System]
        $Lines.Add((New-FrameLine $text $(if ($color) { $color } else { 'DarkGray' })))
    }
    if ($rows.Count -gt $pageSize) {
        $Lines.Add((New-FrameLine (' Rows {0}-{1} / {2}  [Up/Down] scroll' -f ($offset + 1), [math]::Min($rows.Count, $offset + $pageSize), $rows.Count) 'DarkGray'))
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
