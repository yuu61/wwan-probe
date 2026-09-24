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
# Assumed 0.5 dB steps (as ModemManager's XMM plugin does), so the result is in dB.
function ConvertFrom-XcesqResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'XCESQ'
    if ($null -eq $f -or $f.Count -lt 8) { return $null }
    $rssnr = 0
    if (-not [int]::TryParse($f[7], [ref]$rssnr) -or $rssnr -lt -100 -or $rssnr -gt 100) { return $null }
    return $rssnr / 2.0
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

# AT+XACT? -> "+XACT: <AcT>,<PreferredAcT>,<PreferredAcT2>,<band>,<band>,..." (not in the manual).
# Layout as parsed by ModemManager (src/plugins/xmm/mm-modem-helpers-xmm.c):
#   AcT / PreferredAcT: 0=2G 1=3G 2=4G 3=2G+3G 4=3G+4G 5=2G+4G 6=2G+3G+4G (third field ignored)
#   band: <100 = UTRA band, 101..299 = 100 + E-UTRA band, >300 = GSM band in MHz
function ConvertFrom-XactResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'XACT'
    if ($null -eq $f -or $f.Count -lt 4) { return $null }
    $modes = @('2G', '3G', '4G', '2G+3G', '3G+4G', '2G+4G', '2G+3G+4G')
    $act = 0
    if (-not [int]::TryParse($f[0], [ref]$act) -or $act -ge $modes.Count) { return $null }
    $preferred = 0
    $preferredText = if ([int]::TryParse($f[1], [ref]$preferred) -and $preferred -lt $modes.Count) { $modes[$preferred] } else { $null }
    $gsm = @(); $umts = @(); $lte = @()
    foreach ($v in ($f | Select-Object -Skip 3)) {
        $n = 0
        if (-not [int]::TryParse($v, [ref]$n)) { continue }
        if ($n -gt 300) { $gsm += $n }
        elseif ($n -gt 100) { $lte += ($n - 100) }
        elseif ($n -gt 0) { $umts += $n }
    }
    return [pscustomobject]@{
        Allowed   = $modes[$act]   # e.g. "3G+4G"
        Preferred = $preferredText
        GsmBands  = $gsm           # MHz values (900, 1800, ...)
        UmtsBands = $umts          # UTRA band numbers
        LteBands  = $lte           # E-UTRA band numbers
    }
}
