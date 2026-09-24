# Presentation: gauges and colors for signal values.
# Unicode glyphs are only used by the TUI, which switches the console to UTF-8.
# Redirected (plain) output keeps ASCII: under the default console code page
# (e.g. CP932) the block glyphs would turn into '?'.

function Get-RsrpBar([int]$dbm) {
    # Visual bar: -140 to -44 dBm mapped to 0-20 chars
    $normalized = [math]::Max(0, [math]::Min(20, [int](($dbm + 140) / 4.8)))
    $filled = "#" * $normalized
    $empty = "-" * (20 - $normalized)
    return "[$filled$empty]"
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
    if ($Width -le 0) { return "" }
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

# 2-row block sparkline, 16 levels. Each column stacks U+2581..U+2588 (1/8..8/8)
# in the bottom row, then in the top row. Returns @(TopRow, BottomRow).
function Get-BlockSparkline([double[]]$Values, [double]$Min, [double]$Max, [int]$Width) {
    if ($Width -le 0) { return @("", "") }
    if ($null -eq $Values) { $Values = @() }
    $count = [math]::Min($Values.Count, $Width)
    $top = New-Object System.Text.StringBuilder
    $bottom = New-Object System.Text.StringBuilder
    [void]$top.Append(' ', $Width - $count)
    [void]$bottom.Append(' ', $Width - $count)
    for ($i = $Values.Count - $count; $i -lt $Values.Count; $i++) {
        if ([double]::IsNaN($Values[$i])) { [void]$top.Append(' '); [void]$bottom.Append(' '); continue }
        $eighths = (Get-SparkLevel -Value $Values[$i] -Min $Min -Max $Max -Levels 16) + 1          # 1..16
        $low = [math]::Min(8, $eighths)
        $high = $eighths - $low
        [void]$bottom.Append([char](0x2580 + $low))
        if ($high -gt 0) { [void]$top.Append([char](0x2580 + $high)) } else { [void]$top.Append(' ') }
    }
    return @($top.ToString(), $bottom.ToString())
}

function Get-QualityColor([string]$Quality) {
    switch ($Quality) {
        "Excellent" { return "Green" }
        "Good" { return "Cyan" }
        "Fair" { return "Yellow" }
        "Poor" { return "Red" }
        default { return "DarkRed" }
    }
}
