# Domain: LTE signal value conversion / classification (pure, no I/O).

# 3GPP TS 36.133 index -> dBm/dB conversion
function Convert-RsrpIndex([int]$idx) {
    if ($idx -lt 0 -or $idx -gt 97) { return $null }
    return (-141 + $idx)
}

function Convert-RsrqIndex([int]$idx) {
    if ($idx -lt 0 -or $idx -gt 34) { return $null }
    return (-20 + 0.5 * $idx)
}

function Get-RsrpQuality([int]$dbm) {
    if ($dbm -ge -80) { return "Excellent" }
    if ($dbm -ge -90) { return "Good" }
    if ($dbm -ge -100) { return "Fair" }
    if ($dbm -ge -110) { return "Poor" }
    return "Very Poor"
}

function Get-RsrpStatistic([int[]]$Values) {
    if (-not $Values -or $Values.Count -eq 0) { return $null }
    $m = $Values | Measure-Object -Minimum -Maximum -Average
    return [pscustomobject]@{
        Min   = [int]$m.Minimum
        Max   = [int]$m.Maximum
        Avg   = [math]::Round($m.Average, 1)
        Count = $m.Count
    }
}
