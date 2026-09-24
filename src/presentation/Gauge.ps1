# Presentation: ASCII gauges and colors for signal values.
# ASCII only: CP932 consoles render block/box glyphs double-width.

function Get-RsrpBar([int]$dbm) {
    # Visual bar: -140 to -44 dBm mapped to 0-20 chars
    $normalized = [math]::Max(0, [math]::Min(20, [int](($dbm + 140) / 4.8)))
    $filled = "#" * $normalized
    $empty = "-" * (20 - $normalized)
    return "[$filled$empty]"
}

# RSRP history -> ASCII sparkline (-120..-70 dBm mapped to 8 levels).
# Only the most recent $Width samples are shown, right-aligned.
function Get-RsrpSparkline([int[]]$Values, [int]$Width) {
    $levels = '_', '.', '-', '~', '=', '+', '*', '#'
    if ($Width -le 0) { return "" }
    if (-not $Values -or $Values.Count -eq 0) { return (" " * $Width) }
    $start = [math]::Max(0, $Values.Count - $Width)
    $sb = New-Object System.Text.StringBuilder
    for ($i = $start; $i -lt $Values.Count; $i++) {
        $lvl = [int][math]::Floor(($Values[$i] + 120) / 50.0 * $levels.Count)
        $lvl = [math]::Max(0, [math]::Min($levels.Count - 1, $lvl))
        [void]$sb.Append($levels[$lvl])
    }
    return $sb.ToString().PadLeft($Width)
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
