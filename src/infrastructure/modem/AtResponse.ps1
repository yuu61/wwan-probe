# Infrastructure: AT response helpers shared by every vendor's parsers (pure, no I/O).
# Every helper returns $null when the response is missing, not OK ("ERROR"), or the value is invalid.

# LTE bandwidth in resource blocks (QCAINFO, +GTCCINFO, +GTCAINFO) -> MHz.
$script:LteRbBandwidthMHz = @{ 6 = 1.4; 15 = 3; 25 = 5; 50 = 10; 75 = 15; 100 = 20 }
# LTE bandwidth index (QENG <DL_bandwidth>, +XLEC) -> MHz.
$script:LteIndexBandwidthMHz = @(1.4, 3, 5, 10, 15, 20)

# Fields of the first "+<Name>: a,b,c" line, or $null.
function Get-AtResponseField([string]$Response, [string]$Name) {
    if (-not $Response -or $Response -notmatch '(?m)^OK\s*$') { return $null }
    if ($Response -notmatch "(?m)^\+$([regex]::Escape($Name)):\s*(.+?)\s*$") { return $null }
    return , @($Matches[1] -split ',' | ForEach-Object { $_.Trim() })
}

# Fields of every "+<Name>: ..." line (quotes stripped), or $null when the response is not OK.
# Lines of other commands and unprefixed lines are skipped.
function Get-AtResponseLine([string]$Response, [string]$Name) {
    if (-not $Response -or $Response -notmatch '(?m)^OK\s*$') { return $null }
    $lines = @()
    foreach ($m in [regex]::Matches($Response, "(?m)^\+$([regex]::Escape($Name)):\s*(.*?)\s*$")) {
        $lines += , @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"') })
    }
    return , $lines
}

# Integer from an AT field, or $null ("-", empty, or not a number). Accepts a "0x" hex prefix.
function ConvertFrom-AtInt([string]$Text, [switch]$Hex) {
    $Text = "$Text".Trim().Trim('"')
    if ($Text -match '^0x([0-9A-Fa-f]+)$') { $Text = $Matches[1]; $Hex = $true }
    $n = [long]0
    if ($Hex) {
        if ([long]::TryParse($Text, [Globalization.NumberStyles]::HexNumber, $null, [ref]$n)) { return $n }
        return $null
    }
    if ([long]::TryParse($Text, [ref]$n)) { return $n }
    return $null
}
