# Infrastructure: AT status response parsing for Quectel (Qualcomm based) modems (pure, no I/O).
# Reference: Quectel RG50xQ&RM5xxQ Series AT Commands Manual V1.2 (see docs/modem-support.md).
# Not verified on hardware. Every parser returns $null when the response is missing, "ERROR",
# or carries no usable value. Values "-" mean invalid. Cells use the common AT cell shape (AtProfile.ps1).

# LTE bandwidth in resource blocks (QCAINFO, +GTCAINFO) -> MHz.
$script:LteRbBandwidthMHz = @{ 6 = 1.4; 15 = 3; 25 = 5; 50 = 10; 75 = 15; 100 = 20 }
# LTE bandwidth index (QENG <DL_bandwidth>, +XLEC) -> MHz.
$script:LteIndexBandwidthMHz = @(1.4, 3, 5, 10, 15, 20)

function Get-QuectelLteDbm([string]$Text) {
    $v = ConvertFrom-AtInt $Text
    if ($null -eq $v -or $v -lt -140 -or $v -gt -44) { return $null }
    return [int]$v
}

function Get-QuectelLteDb([string]$Text) {
    $v = ConvertFrom-AtInt $Text
    if ($null -eq $v -or $v -lt -20 -or $v -gt -3) { return $null }
    return [int]$v
}

# AT+QENG="servingcell" -> serving cells. Layouts (manual 5.20):
#   "servingcell",<state>,"LTE",<is_tdd>,<MCC>,<MNC>,<cellID>,<PCID>,<earfcn>,<band>,<UL_bw>,<DL_bw>,<TAC>,<RSRP>,<RSRQ>,...
#   EN-DC: "servingcell",<state> / "LTE",<is_tdd>,... (same LTE fields) / "NR5G-NSA",<MCC>,<MNC>,<PCID>,<RSRP>,<SINR>,<RSRQ>,<ARFCN>,...
#   "servingcell",<state>,"NR5G-SA",<duplex>,<MCC>,<MNC>,<cellID>,<PCID>,<TAC>,<ARFCN>,...
#   "servingcell",<state>,"WCDMA",<MCC>,<MNC>,<LAC>,<cellID>,<uarfcn>,...
#   "servingcell",<state>,"GSM",<MCC>,<MNC>,<LAC>,<cellID>,<BSIC>,<arfcn>,... (EC2x manual; not in RM5xx)
# Fields after RSRQ differ between module families (and the SINR formula conflicts), so they are not read.
# LTE cells also carry DlBandwidthMHz (from the index 0..5) for the CA fallback.
function ConvertFrom-QengServingResponse([string]$Response) {
    $lines = Get-AtResponseLine $Response 'QENG'
    if ($null -eq $lines) { return $null }
    $cells = @()
    foreach ($f in $lines) {
        $r = [array]::IndexOf($f, ($f | Where-Object { $_ -in 'LTE', 'WCDMA', 'GSM', 'NR5G-SA', 'NR5G-NSA' } | Select-Object -First 1))
        if ($r -lt 0) { continue }
        $at = { param($i) if ($r + $i -lt $f.Count) { $f[$r + $i] } }
        switch ($f[$r]) {
            'LTE' {
                $bw = ConvertFrom-AtInt (& $at 9)
                $cells += [pscustomobject]@{
                    Rat = 'LTE'; Role = 'Serving'; Channel = ConvertFrom-AtInt (& $at 6)
                    Earfcn = ConvertFrom-AtInt (& $at 6); Pci = ConvertFrom-AtInt (& $at 5)
                    CellId = ConvertFrom-AtInt (& $at 4) -Hex; Tac = ConvertFrom-AtInt (& $at 10) -Hex
                    RsrpDbm = Get-QuectelLteDbm (& $at 11); RsrqDb = Get-QuectelLteDb (& $at 12)
                    DlBandwidthMHz = if ($null -ne $bw -and $bw -ge 0 -and $bw -lt 6) { $script:LteIndexBandwidthMHz[$bw] }
                }
            }
            'WCDMA' { $cells += [pscustomobject]@{ Rat = 'UMTS'; Role = 'Serving'; Channel = ConvertFrom-AtInt (& $at 5) } }
            'GSM' { $cells += [pscustomobject]@{ Rat = 'GSM'; Role = 'Serving'; Channel = ConvertFrom-AtInt (& $at 6) } }
            'NR5G-SA' { $cells += [pscustomobject]@{ Rat = 'NR'; Role = 'Serving'; Channel = ConvertFrom-AtInt (& $at 7) } }
            'NR5G-NSA' { $cells += [pscustomobject]@{ Rat = 'NR'; Role = 'Serving'; Channel = ConvertFrom-AtInt (& $at 7) } }
        }
    }
    return , $cells
}

# AT+QENG="neighbourcell" -> neighbor cells.
#   "neighbourcell intra"|"neighbourcell inter","LTE",<earfcn>,<PCID>,<RSRQ>,<RSRP>,...   (LTE mode)
#   "neighbourcell","LTE",<earfcn>,<PCID>,<RSRP>,<RSRQ>,...                              (WCDMA mode, RSRP first)
#   "neighbourcell","WCDMA",<uarfcn>,...
#   "neighbourcell","GSM",... (channel position not documented in the RM5xx manual -> $null)
# Inter-frequency entries without a measurement ("-") are kept for the RAT check but have no RSRP.
function ConvertFrom-QengNeighbourResponse([string]$Response) {
    $lines = Get-AtResponseLine $Response 'QENG'
    if ($null -eq $lines) { return $null }
    $cells = @()
    foreach ($f in $lines) {
        if ($f.Count -lt 3 -or $f[0] -notlike 'neighbourcell*') { continue }
        switch ($f[1]) {
            'LTE' {
                $rsrpFirst = $f[0] -eq 'neighbourcell'
                $cells += [pscustomobject]@{
                    Rat = 'LTE'; Role = 'Neighbor'; Channel = ConvertFrom-AtInt $f[2]
                    Earfcn = ConvertFrom-AtInt $f[2]; Pci = ConvertFrom-AtInt $f[3]
                    RsrpDbm = Get-QuectelLteDbm $f[$(if ($rsrpFirst) { 4 } else { 5 })]
                    RsrqDb = Get-QuectelLteDb $f[$(if ($rsrpFirst) { 5 } else { 4 })]
                }
            }
            'WCDMA' { $cells += [pscustomobject]@{ Rat = 'UMTS'; Role = 'Neighbor'; Channel = ConvertFrom-AtInt $f[2] } }
            'GSM' { $cells += [pscustomobject]@{ Rat = 'GSM'; Role = 'Neighbor'; Channel = $null } }
        }
    }
    return , $cells
}

# AT+QCAINFO -> @{ Cells; BandwidthsMHz; PccRssnr } for the LTE carriers, or $null without a PCC line.
#   "PCC",<freq>,<bandwidth>,<band>,<pcell_state>,<PCID>,<RSRP>,<RSRQ>,<RSSI>,<RSSNR>
#   "SCC",<freq>,<bandwidth>,<band>,<scell_state>,<PCID>,<RSRP>,<RSRQ>,<RSSI>,<RSSNR>
# bandwidth is in resource blocks; scell_state 0 = deconfigured (not counted); RSSNR is in dB (-10..30).
# Carriers whose <band> is not "LTE BAND n" (NR) are skipped.
function ConvertFrom-QcainfoResponse([string]$Response) {
    $lines = Get-AtResponseLine $Response 'QCAINFO'
    if ($null -eq $lines) { return $null }
    $pcc = $null
    $bandwidths = @()
    foreach ($f in $lines) {
        if ($f.Count -lt 5 -or $f[3] -notmatch '^LTE BAND') { continue }
        $rb = ConvertFrom-AtInt $f[2]
        $mhz = if ($null -ne $rb -and $script:LteRbBandwidthMHz.ContainsKey([int]$rb)) { $script:LteRbBandwidthMHz[[int]$rb] }
        if ($f[0] -eq 'PCC') { $pcc = $f; $bandwidths = @($mhz) + $bandwidths }
        elseif ($f[0] -eq 'SCC' -and (ConvertFrom-AtInt $f[4]) -ne 0) { $bandwidths += $mhz }
    }
    if ($null -eq $pcc) { return $null }
    $rssnr = if ($pcc.Count -ge 10) { ConvertFrom-AtInt $pcc[9] }
    return [pscustomobject]@{
        Cells         = $bandwidths.Count
        BandwidthsMHz = $bandwidths
        PccRssnr      = if ($null -ne $rssnr -and $rssnr -ge -10 -and $rssnr -le 30) { [double]$rssnr }
    }
}

# AT+QSINR -> "+QSINR: <PRX>,<DRX>,<RX2>,<RX3>,<sysmode>" (dB). Returns the PRX path in LTE mode.
function ConvertFrom-QsinrResponse([string]$Response) {
    $f = Get-AtResponseField $Response 'QSINR'
    if ($null -eq $f -or $f.Count -lt 5 -or $f[4].Trim('"') -ne 'LTE') { return $null }
    $v = ConvertFrom-AtInt $f[0]
    if ($null -eq $v -or $v -lt -20 -or $v -gt 30) { return $null }
    return [double]$v
}

# AT+QTEMP -> hottest sensor in Celsius. Two layouts exist:
#   RM5xx: one line per sensor, +QTEMP: "<sensor>","<temp>"
#   EM12/EG25 family: +QTEMP: <pmic_temp>,<xo_temp>,<pa_temp>
# Out-of-range readings (absent sensors) are ignored.
function ConvertFrom-QtempResponse([string]$Response) {
    $lines = Get-AtResponseLine $Response 'QTEMP'
    if ($null -eq $lines) { return $null }
    $max = $null
    foreach ($f in $lines) {
        foreach ($text in $f) {
            $v = ConvertFrom-AtInt $text
            if ($null -eq $v -or $v -lt -40 -or $v -gt 125) { continue }
            if ($null -eq $max -or $v -gt $max) { $max = [int]$v }
        }
    }
    return $max
}

# AT+QNWPREFCFG="mode_pref" / "gw_band" / "lte_band" / "nr5g_band" -> RatConfig (see ConvertFrom-XactResponse).
# mode_pref is "AUTO" (every RAT the module supports: WCDMA & LTE & NR) or RATs joined with ':'.
# No preferred RAT is read (rat_acq_order is a priority list), so Preferred is $null.
function ConvertFrom-QnwprefcfgResponse([hashtable]$Responses) {
    $value = {
        param($name)
        foreach ($r in $Responses.Values) {
            $lines = Get-AtResponseLine $r 'QNWPREFCFG'
            foreach ($f in $lines) {
                if ($f.Count -ge 2 -and $f[0] -eq $name) { return $f[1] }
            }
        }
    }
    $mode = & $value 'mode_pref'
    if (-not $mode) { return $null }
    # GSM is not in the RM5xx manual; mapped so a module that lists it still gets the 2G warning.
    $names = @{ GSM = '2G'; WCDMA = '3G'; LTE = '4G'; NR5G = '5G' }
    $ratNames = @{ GSM = 'GSM'; WCDMA = 'UMTS'; LTE = 'LTE'; NR5G = 'NR' }
    $allowedRats = if ($mode -eq 'AUTO') { @('UMTS', 'LTE', 'NR') }
    else { @($mode -split ':' | ForEach-Object { if ($ratNames[$_]) { $ratNames[$_] } else { $_ } }) }
    $allowed = if ($mode -eq 'AUTO') { '3G+4G+5G (AUTO)' }
    else { (@($mode -split ':' | ForEach-Object { if ($names[$_]) { $names[$_] } else { $_ } }) | Sort-Object) -join '+' }
    $bands = { param($name) @((& $value $name) -split ':' | ForEach-Object { ConvertFrom-AtInt $_ } | Where-Object { $null -ne $_ }) }
    return [pscustomobject]@{
        AllowedRats = @($allowedRats)
        Allowed     = $allowed
        Preferred   = $null
        GsmBands    = @()
        # @() keeps a single band or none an array (a script block's output is unrolled).
        UmtsBands   = @(& $bands 'gw_band')
        LteBands    = @(& $bands 'lte_band')
        NrBands     = @(& $bands 'nr5g_band')
    }
}
