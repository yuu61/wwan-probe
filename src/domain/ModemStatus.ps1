# Domain: AT status response parsing (pure, no I/O).
# Reference: FIBOCOM L860 AT Commands User Manual V3.2.3 (see docs/neighbor-cells.md).
# Every parser returns $null when the response is missing, "ERROR", or the value is invalid.

# Fields of the first "+<Name>: a,b,c" line, or $null.
function Get-AtResponseField([string]$Response, [string]$Name) {
    if (-not $Response -or $Response -notmatch '(?m)^OK\s*$') { return $null }
    if ($Response -notmatch "(?m)^\+$([regex]::Escape($Name)):\s*(.+?)\s*$") { return $null }
    return , @($Matches[1] -split ',' | ForEach-Object { $_.Trim() })
}

# AT+MTSM=1 -> "+MTSM: <Temp>" (Celsius, -40..125)
function ConvertFrom-MtsmResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'MTSM'
    if ($null -eq $f) { return $null }
    $temp = 0
    if (-not [int]::TryParse($f[0], [ref]$temp) -or $temp -lt -40 -or $temp -gt 125) { return $null }
    return $temp
}

# AT+XCESQ? -> "+XCESQ: <n>,<rxlev>,<ber>,<rscp>,<ecno>,<rsrq>,<rsrp>,<rssnr>,..."
# rssnr range is -100..100 (255 = unknown); the manual does not state its unit.
function ConvertFrom-XcesqResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'XCESQ'
    if ($null -eq $f -or $f.Count -lt 8) { return $null }
    $rssnr = 0
    if (-not [int]::TryParse($f[7], [ref]$rssnr) -or $rssnr -lt -100 -or $rssnr -gt 100) { return $null }
    return $rssnr
}

# AT+XLEC? -> "+XLEC: <n>,<no_of_cells>,<bandwidth>[,<bandwidth>...][,<undocumented>...]"
# no_of_cells: 0 = not on LTE, 1 = primary cell only, 2..5 = secondary cells added.
# bandwidth:   0..5 = 1.4/3/5/10/15/20 MHz, 255 = invalid.
function ConvertFrom-XlecResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'XLEC'
    if ($null -eq $f -or $f.Count -lt 2) { return $null }
    $cells = 0
    if (-not [int]::TryParse($f[1], [ref]$cells) -or $cells -lt 0 -or $cells -gt 5) { return $null }
    $mhz = @(1.4, 3, 5, 10, 15, 20)
    $bandwidths = @()
    for ($i = 0; $i -lt $cells -and (2 + $i) -lt $f.Count; $i++) {
        $bw = 0
        $valid = [int]::TryParse($f[2 + $i], [ref]$bw) -and $bw -ge 0 -and $bw -lt $mhz.Count
        $bandwidths += if ($valid) { $mhz[$bw] } else { $null }
    }
    return [pscustomobject]@{ Cells = $cells; BandwidthsMHz = $bandwidths }
}

# AT+XACT? -> "+XACT: <...>,<band>,<band>,..." (not in the manual).
# Values 101..199 are read as 100 + LTE band number, matching +XCCINFO <band_info>
# (inferred, e.g. band_info 118 while camped on EARFCN 5900 = B18).
function ConvertFrom-XactResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'XACT'
    if ($null -eq $f) { return $null }
    $bands = @()
    foreach ($v in $f) {
        $n = 0
        if ([int]::TryParse($v, [ref]$n) -and $n -gt 100 -and $n -lt 200) { $bands += ($n - 100) }
    }
    return , $bands
}
