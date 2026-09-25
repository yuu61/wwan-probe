# Presentation: history charts (definitions, visibility, height, scale and sparkline rows).

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
