# Domain: signal classification and statistics (pure, no I/O).

function Get-RsrpQuality($dbm) {
    if ($null -eq $dbm) { return $null }
    if ($dbm -ge -80) { return 'Excellent' }
    if ($dbm -ge -90) { return 'Good' }
    if ($dbm -ge -100) { return 'Fair' }
    if ($dbm -ge -110) { return 'Poor' }
    return 'Very Poor'
}

# Min/Max/Avg of a signal series; NaN (missing sample) is ignored.
function Get-SignalStatistic([double[]]$Values) {
    $valid = @($Values | Where-Object { -not [double]::IsNaN($_) })
    if ($valid.Count -eq 0) { return $null }
    $m = $valid | Measure-Object -Minimum -Maximum -Average
    return [pscustomobject]@{
        Min   = $m.Minimum
        Max   = $m.Maximum
        Avg   = [math]::Round($m.Average, 1)
        Count = $m.Count
    }
}
