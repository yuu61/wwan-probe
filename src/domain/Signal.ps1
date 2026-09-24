# Domain: LTE signal value conversion / classification (pure, no I/O).

# 3GPP TS 36.133 index -> dBm/dB conversion (AT+XMCI / +XCESQ / +GTCCINFO / +CESQ use this scale)
function Convert-RsrpIndex([int]$idx) {
    if ($idx -lt 0 -or $idx -gt 97) { return $null }
    return (-141 + $idx)
}

function Convert-RsrqIndex([int]$idx) {
    if ($idx -lt 0 -or $idx -gt 34) { return $null }
    return (-20 + 0.5 * $idx)
}

# WinRT MobileBroadbandCellLte RSRP / RSRQ -> dBm / dB, or $null.
# The MBIM spec (MBIM_LTE_SERVING_CELL_INFO / MBIM_LTE_MRL_INFO) defines RSRP -140..-44 dBm and
# RSRQ -20..-3 dB, but the L860-GL reports 3GPP TS 36.133 indices (RSRP 0..97, RSRQ 0..34).
# The ranges do not overlap, so both are accepted. Untyped so a missing value stays $null.
function ConvertFrom-WinRtRsrp($Value) {
    if ($null -eq $Value) { return $null }
    $v = [double]$Value
    if ($v -ge -140 -and $v -le -44) { return [int][math]::Round($v) }
    if ($v -ge 0 -and $v -le 97 -and $v -eq [math]::Floor($v)) { return Convert-RsrpIndex ([int]$v) }
    return $null
}

function ConvertFrom-WinRtRsrq($Value) {
    if ($null -eq $Value) { return $null }
    $v = [double]$Value
    if ($v -ge -20 -and $v -le -3) { return $v }
    if ($v -ge 0 -and $v -le 34 -and $v -eq [math]::Floor($v)) { return Convert-RsrqIndex ([int]$v) }
    return $null
}

function Get-RsrpQuality([int]$dbm) {
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
