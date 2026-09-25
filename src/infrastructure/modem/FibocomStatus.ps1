# Infrastructure: AT status response parsing for Fibocom "GT" command modems (FM350-GL, MediaTek T700) (pure, no I/O).
# Reference: FM350 AT Commands User Manual V2.10 (see docs/modem-support.md). Number bases of
# +GTCCINFO fields were taken from real FM350 output (TAC / cell ID hex, EARFCN / PCI decimal).
# Not verified on hardware. Every parser returns $null when the response is missing or "ERROR".
# Depends on ModemStatus.ps1 (Get-AtResponseLine, ConvertFrom-AtInt) and QuectelStatus.ps1
# ($script:LteRbBandwidthMHz).

# +GTCCINFO rsrp / rsrq index -> dBm / dB, or $null. rsrp 0 means "below -140 dBm or not detectable"
# and is treated as not measured; 255 = unknown for both.
function ConvertFrom-GtIndex([string]$Text, [string]$Kind) {
    $v = ConvertFrom-AtInt $Text
    if ($null -eq $v -or $v -lt 0) { return $null }
    if ($Kind -eq 'Rsrp') { return $(if ($v -gt 0) { Convert-RsrpIndex ([int]$v) }) }
    return Convert-RsrqIndex ([int]$v)
}

# AT+GTCCINFO? -> cells. Data lines follow "+GTCCINFO:" without a prefix (optionally after
# "LTE service cell:" style headings):
#   <IsServiceCell 1|2>,<rat 2=WCDMA 4=LTE 9=NR>,<mcc>,<mnc>,<tac|lac hex>,<cellid hex>,<arfcn>,<pci>,...
#   LTE serving:  ...,<band>,<bandwidth RB>,<rssnr_value>,<rxlev>,<rsrp idx>,<rsrq idx>
#   LTE neighbor: ...,<bandwidth RB>,<rxlev>,<rsrp idx>,<rsrq idx>
# rssnr_value is -100..100 in 0.5 dB steps (255 = unknown); rsrp / rsrq are 3GPP TS 36.133 indices.
# LTE serving cells also carry Rssnr (dB) and DlBandwidthMHz.
function ConvertFrom-GtccinfoResponse([string]$Response) {
    if (-not $Response -or $Response -notmatch '(?m)^OK\s*$' -or $Response -notmatch '\+GTCCINFO:') { return $null }
    $cells = @()
    foreach ($line in ($Response -split "`r?`n")) {
        $line = ($line -replace '^\+GTCCINFO:\s*', '').Trim()
        if ($line -notmatch '^[12],\d+,') { continue }
        $f = @($line -split ',' | ForEach-Object { $_.Trim() })
        if ($f.Count -lt 8) { continue }
        $serving = $f[0] -eq '1'
        $role = if ($serving) { 'Serving' } else { 'Neighbor' }
        $channel = ConvertFrom-AtInt $f[6]
        switch ($f[1]) {
            '2' { $cells += [pscustomobject]@{ Rat = 'UMTS'; Role = $role; Channel = $channel } }
            '9' { $cells += [pscustomobject]@{ Rat = 'NR'; Role = $role; Channel = $channel } }
            '4' {
                $i = if ($serving) { 12 } else { 10 }  # rsrp index position
                if ($f.Count -le $i + 1) { continue }
                $cell = [ordered]@{
                    Rat = 'LTE'; Role = $role; Channel = $channel; Earfcn = $channel
                    Pci = ConvertFrom-AtInt $f[7]; Tac = ConvertFrom-AtInt $f[4] -Hex; CellId = ConvertFrom-AtInt $f[5] -Hex
                    RsrpDbm = ConvertFrom-GtIndex $f[$i] 'Rsrp'
                    RsrqDb = ConvertFrom-GtIndex $f[$i + 1] 'Rsrq'
                }
                if ($serving) {
                    $rb = ConvertFrom-AtInt $f[9]
                    $cell.DlBandwidthMHz = if ($null -ne $rb -and $script:LteRbBandwidthMHz.ContainsKey([int]$rb)) { $script:LteRbBandwidthMHz[[int]$rb] }
                    $snr = ConvertFrom-AtInt $f[10]
                    $cell.Rssnr = if ($null -ne $snr -and $snr -ge -100 -and $snr -le 100) { $snr / 2.0 }
                }
                $cells += [pscustomobject]$cell
            }
        }
    }
    return , $cells
}

# AT+GTCAINFO? -> @{ Cells; BandwidthsMHz } for LTE, or $null without an LTE PCC line.
#   PCC:<band>,<pci>,<earfcn>,<dl_bandwidth RB>,...
#   SCC<n>:<scell_state>,<ul_configured>,<band>,<pci>,<earfcn>,<dl_bandwidth RB>,...
# band 101..199 = 100 + E-UTRA band (NR carriers, band >= 501, are skipped).
# The first carrier may follow "+GTCAINFO:" on the same line (as fibocom-connect-fm350 also accepts).
function ConvertFrom-GtcainfoResponse([string]$Response) {
    if (-not $Response -or $Response -notmatch '(?m)^OK\s*$') { return $null }
    $pcc = $false
    $bandwidths = @()
    foreach ($line in ($Response -split "`r?`n")) {
        if ($line -notmatch '^\s*(?:\+GTCAINFO:\s*)?(PCC|SCC\s*\d*)\s*:\s*(.+?)\s*$') { continue }
        $f = @($Matches[2] -split ',' | ForEach-Object { $_.Trim() })
        $isPcc = $Matches[1] -eq 'PCC'
        $o = if ($isPcc) { 0 } else { 2 }  # offset of <band>
        if ($f.Count -le $o + 3) { continue }
        $band = ConvertFrom-AtInt $f[$o]
        if ($null -eq $band -or $band -le 100 -or $band -ge 200) { continue }
        $rb = ConvertFrom-AtInt $f[$o + 3]
        $mhz = if ($null -ne $rb -and $script:LteRbBandwidthMHz.ContainsKey([int]$rb)) { $script:LteRbBandwidthMHz[[int]$rb] }
        if ($isPcc) { $pcc = $true; $bandwidths = @($mhz) + $bandwidths } else { $bandwidths += $mhz }
    }
    if (-not $pcc) { return $null }
    return [pscustomobject]@{ Cells = $bandwidths.Count; BandwidthsMHz = $bandwidths }
}

# AT+GTSENRDTEMP=1 -> "+GTSENRDTEMP: <sensor_id>,<temperature>" (sensor 1 = soc_max).
# The manual gives no unit; FM350 tools (fm350-util, fibocom-connect-fm350) divide by 1000 (milli-Celsius).
function ConvertFrom-GtsenrdtempResponse([string]$Response) {
    $lines = Get-AtResponseLine $Response 'GTSENRDTEMP'
    if ($null -eq $lines -or $lines.Count -eq 0 -or $lines[0].Count -lt 2) { return $null }
    $v = ConvertFrom-AtInt $lines[0][1]
    if ($null -eq $v) { return $null }
    $c = [math]::Round($v / 1000.0, 1)
    if ($c -lt -40 -or $c -gt 125) { return $null }
    return $c
}

# AT+GTACT? -> "+GTACT: <rat>,<PreferredAct1>,<PreferredAct2>,<band>,..." -> RatConfig (see ConvertFrom-XactResponse).
#   rat: 1=UMTS 2=LTE 4=LTE/UMTS 10=Automatic (queried back as 20) 14=NR 16=NR/WCDMA 17=NR/LTE 20=NR/WCDMA/LTE
#   PreferredAct: 2=WCDMA 3=LTE 6=NR
#   band: 0 = automatic, 1..99 = UMTS band, 101..199 = 100 + LTE band, "50" + n = NR band n (501, 5010, 50512)
function ConvertFrom-GtactResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'GTACT'
    if ($null -eq $f -or $f.Count -lt 1) { return $null }
    $rats = @{ 1 = '3G'; 2 = '4G'; 4 = '3G+4G'; 10 = '3G+4G+5G (Auto)'; 14 = '5G'; 16 = '3G+5G'; 17 = '4G+5G'; 20 = '3G+4G+5G' }
    $ratSets = @{ 1 = @('UMTS'); 2 = @('LTE'); 4 = @('UMTS', 'LTE'); 10 = @('UMTS', 'LTE', 'NR'); 14 = @('NR'); 16 = @('UMTS', 'NR'); 17 = @('LTE', 'NR'); 20 = @('UMTS', 'LTE', 'NR') }
    $prefs = @{ 2 = '3G'; 3 = '4G'; 6 = '5G' }
    $rat = ConvertFrom-AtInt $f[0]
    if ($null -eq $rat -or -not $rats.ContainsKey([int]$rat)) { return $null }
    $pref = if ($f.Count -gt 1) { ConvertFrom-AtInt $f[1] }
    $umts = @(); $lte = @(); $nr = @()
    foreach ($text in ($f | Select-Object -Skip 3)) {
        if ($text -match '^50(\d+)$') { $nr += [int]$Matches[1]; continue }
        $n = ConvertFrom-AtInt $text
        if ($null -eq $n -or $n -le 0) { continue }
        if ($n -gt 100 -and $n -lt 200) { $lte += [int]($n - 100) }
        elseif ($n -lt 100) { $umts += [int]$n }
    }
    return [pscustomobject]@{
        AllowedRats = $ratSets[[int]$rat]
        Allowed     = $rats[[int]$rat]
        Preferred   = if ($null -ne $pref -and $prefs.ContainsKey([int]$pref)) { $prefs[[int]$pref] }
        GsmBands    = @()
        UmtsBands   = $umts
        LteBands    = $lte
        NrBands     = $nr
    }
}
