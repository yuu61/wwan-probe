# Presentation: gauges and colors for signal values.
# Unicode glyphs are only used by the TUI, which switches the console to UTF-8.
# Redirected (plain) output keeps ASCII: under the default console code page
# (e.g. CP932) the block glyphs would turn into '?'.

function Get-RsrpBar([int]$dbm) {
    # Visual bar: -140 to -44 dBm mapped to 0-20 chars
    $normalized = [math]::Max(0, [math]::Min(20, [int](($dbm + 140) / 4.8)))
    $filled = '#' * $normalized
    $empty = '-' * (20 - $normalized)
    return "[$filled$empty]"
}

# Auto scale for a sparkline: [min, max] of the valid (non-NaN) values, snapped outward
# to multiples of $Step, widened (around the data center) to at least $MinSpan so a steady
# signal does not magnify noise, then shifted/clamped into [$Floor, $Ceiling].
# With no valid values the whole [$Floor, $Ceiling] range is returned.
function Get-AutoScale {
    param([double[]]$Values, [double]$Step, [double]$MinSpan, [double]$Floor, [double]$Ceiling)

    $valid = @($Values | Where-Object { -not [double]::IsNaN($_) })
    if ($valid.Count -eq 0) { return [pscustomobject]@{ Min = $Floor; Max = $Ceiling } }
    $m = $valid | Measure-Object -Minimum -Maximum
    $lo = [math]::Floor($m.Minimum / $Step) * $Step
    $hi = [math]::Ceiling($m.Maximum / $Step) * $Step
    $need = [math]::Ceiling($MinSpan / $Step) * $Step
    if ($hi - $lo -lt $need) {
        $lo = [math]::Min($lo, [math]::Floor((($m.Minimum + $m.Maximum) / 2 - $need / 2) / $Step) * $Step)
        $hi = [math]::Max($hi, $lo + $need)
    }
    if ($lo -lt $Floor) { $hi = [math]::Min($Ceiling, $hi + ($Floor - $lo)); $lo = $Floor }
    if ($hi -gt $Ceiling) { $lo = [math]::Max($Floor, $lo - ($hi - $Ceiling)); $hi = $Ceiling }
    return [pscustomobject]@{ Min = $lo; Max = $hi }
}

# Scale anchored at 0 for non-negative series with no natural range (throughput):
# Max is the max valid value rounded up to 1/2/5 x 10^n, at least $MinMax so an idle
# link does not magnify noise.
function Get-ZeroBasedScale([double[]]$Values, [double]$MinMax) {
    $valid = @($Values | Where-Object { -not [double]::IsNaN($_) })
    $max = if ($valid.Count -eq 0) { 0 } else { ($valid | Measure-Object -Maximum).Maximum }
    if ($max -le $MinMax) { return [pscustomobject]@{ Min = 0; Max = $MinMax } }
    $p = [math]::Pow(10, [math]::Floor([math]::Log10($max)))
    foreach ($m in 1, 2, 5, 10) {
        if ($m * $p -ge $max) { return [pscustomobject]@{ Min = 0; Max = $m * $p } }
    }
}

# Sparklines map [Min, Max] linearly onto N levels (values outside are clamped).
# Only the most recent $Width samples are shown, right-aligned. NaN (missing sample)
# is drawn as a blank column so series sharing a time axis stay aligned.

function Get-SparkLevel([double]$Value, [double]$Min, [double]$Max, [int]$Levels) {
    $lvl = [int][math]::Floor(($Value - $Min) / ($Max - $Min) * $Levels)
    return [math]::Max(0, [math]::Min($Levels - 1, $lvl))
}

# ASCII sparkline, 8 levels.
function Get-Sparkline([double[]]$Values, [double]$Min, [double]$Max, [int]$Width) {
    $glyphs = '_', '.', '-', '~', '=', '+', '*', '#'
    if ($Width -le 0) { return '' }
    if ($null -eq $Values) { $Values = @() }
    $count = [math]::Min($Values.Count, $Width)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append(' ', $Width - $count)
    for ($i = $Values.Count - $count; $i -lt $Values.Count; $i++) {
        if ([double]::IsNaN($Values[$i])) { [void]$sb.Append(' '); continue }
        [void]$sb.Append($glyphs[(Get-SparkLevel -Value $Values[$i] -Min $Min -Max $Max -Levels $glyphs.Count)])
    }
    return $sb.ToString()
}

# Multi-row block sparkline, 8 x $Rows levels. Each column stacks U+2581..U+2588
# (1/8..8/8) from the bottom row upward. Returns $Rows strings, top row first.
function Get-BlockSparkline([double[]]$Values, [double]$Min, [double]$Max, [int]$Width, [int]$Rows = 2) {
    $Rows = [math]::Max(1, $Rows)
    $builders = @(for ($r = 0; $r -lt $Rows; $r++) { New-Object System.Text.StringBuilder })   # bottom row first
    if ($Width -le 0) { return @($builders | ForEach-Object { '' }) }
    if ($null -eq $Values) { $Values = @() }
    $count = [math]::Min($Values.Count, $Width)
    foreach ($b in $builders) { [void]$b.Append(' ', $Width - $count) }
    for ($i = $Values.Count - $count; $i -lt $Values.Count; $i++) {
        if ([double]::IsNaN($Values[$i])) { foreach ($b in $builders) { [void]$b.Append(' ') }; continue }
        $eighths = (Get-SparkLevel -Value $Values[$i] -Min $Min -Max $Max -Levels (8 * $Rows)) + 1   # 1..8*Rows
        for ($r = 0; $r -lt $Rows; $r++) {
            $fill = [math]::Max(0, [math]::Min(8, $eighths - 8 * $r))
            if ($fill -gt 0) { [void]$builders[$r].Append([char](0x2580 + $fill)) } else { [void]$builders[$r].Append(' ') }
        }
    }
    [array]::Reverse($builders)
    return @($builders | ForEach-Object { $_.ToString() })
}

function Get-QualityColor([string]$Quality) {
    switch ($Quality) {
        'Excellent' { return 'Green' }
        'Good' { return 'Cyan' }
        'Fair' { return 'Yellow' }
        'Poor' { return 'Red' }
        default { return 'DarkRed' }
    }
}
