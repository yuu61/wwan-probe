# Domain: vendor AT command sets ("profiles") and their normalized results (pure, no I/O).
# The profile is chosen at startup by sending each Probe command in order; the first answered with
# OK wins (Intel first, so the tested L860-GL path is unchanged). Only Intel was verified on hardware.
#   Status = commands sent every sample (slowest / least important last: a timeout skips the rest)
#   Config = commands sent once at startup for the RAT / band configuration
#   Source = label of the cell list in 2G/3G downgrade reasons
#
# Common AT cell shape (ConvertFrom-XmciResponse / -QengServingResponse / -QengNeighbourResponse / -GtccinfoResponse):
#   Rat = GSM/UMTS/LTE/NR, Role = Serving/Neighbor, Channel = ARFCN/UARFCN/EARFCN/NR-ARFCN ($null = unknown),
#   LTE cells also: Earfcn, Pci, RsrpDbm, RsrqDb ($null = not measured) and optionally Tac, CellId.
$script:AtProfiles = @(
    [pscustomobject]@{
        Id = 'Intel'; Name = 'Intel XMM (+X commands)'; Probe = 'AT+XLEC?'; Source = 'XMCI'
        # XMCI=0 returns the stored measurements immediately; XMCI=1 waits for a fresh serving-cell
        # measurement and was seen to hang for >10 s on a weak cell.
        Status = @('AT+MTSM=1', 'AT+XCESQ?', 'AT+XLEC?', 'AT+XMCI=0')
        Config = @('AT+XACT?')
    }
    [pscustomobject]@{
        Id = 'Quectel'; Name = 'Quectel (+Q commands)'; Probe = 'AT+QENG=?'; Source = 'QENG'
        Status = @('AT+QTEMP', 'AT+QCAINFO', 'AT+QSINR', 'AT+QENG="servingcell"', 'AT+QENG="neighbourcell"')
        Config = @('AT+QNWPREFCFG="mode_pref"', 'AT+QNWPREFCFG="gw_band"', 'AT+QNWPREFCFG="lte_band"', 'AT+QNWPREFCFG="nr5g_band"')
    }
    [pscustomobject]@{
        Id = 'FibocomGt'; Name = 'Fibocom (+GT commands)'; Probe = 'AT+GTCAINFO=?'; Source = 'GTCCINFO'
        Status = @('AT+GTSENRDTEMP=1', 'AT+GTCAINFO?', 'AT+GTCCINFO?')
        Config = @('AT+GTACT?')
    }
)

# LTE neighbor cells (RsrpDbm, RsrqDb, Band, Earfcn, Pci) from common AT cells; $null when the
# cell list is unavailable. Neighbors without an RSRP measurement or EARFCN are skipped.
function Get-LteNeighbor($Cells) {
    if ($null -eq $Cells) { return $null }
    $neighbors = @()
    foreach ($cell in $Cells) {
        if ($cell.Rat -ne 'LTE' -or $cell.Role -ne 'Neighbor') { continue }
        if ($null -eq $cell.RsrpDbm -or $null -eq $cell.Earfcn) { continue }
        $neighbors += [pscustomobject]@{
            RsrpDbm = $cell.RsrpDbm
            RsrqDb  = $cell.RsrqDb
            Band    = Get-EarfcnBand $cell.Earfcn
            Earfcn  = $cell.Earfcn
            Pci     = $cell.Pci
        }
    }
    return , $neighbors
}

# Single-carrier CA value from an LTE serving cell when no CA command answered.
function Get-SingleCarrierCa($Cells) {
    if ($null -eq $Cells) { return $null }
    $lte = @($Cells | Where-Object { $_.Rat -eq 'LTE' -and $_.Role -eq 'Serving' } | Select-Object -First 1)
    if ($lte.Count -gt 0) { return [pscustomobject]@{ Cells = 1; BandwidthsMHz = @($lte[0].DlBandwidthMHz) } }
    if (@($Cells | Where-Object { $_.Role -eq 'Serving' }).Count -gt 0) { return [pscustomobject]@{ Cells = 0; BandwidthsMHz = @() } }
    return $null
}

# Per-sample status from $Responses (@{ command = response }, Invoke-ModemAtCommand) of $AtProfile.Status:
#   Cells     = common AT cells for the downgrade check ($null = unavailable)
#   Neighbors = Get-LteNeighbor result ($null = unavailable)
#   TempC (C), Rssnr (dB), Ca = @{ Cells; BandwidthsMHz } ($null = unavailable)
function ConvertFrom-AtStatus($AtProfile, [hashtable]$Responses) {
    $status = [ordered]@{ Cells = $null; Neighbors = $null; TempC = $null; Rssnr = $null; Ca = $null }
    switch ($AtProfile.Id) {
        'Intel' {
            $xmci = $Responses['AT+XMCI=0']
            if ($xmci -and $xmci -match '(?m)^OK\s*$') { $status.Cells = @(ConvertFrom-XmciResponse $xmci) }
            $status.Neighbors = Get-LteNeighbor $status.Cells
            $status.TempC = ConvertFrom-MtsmResponse $Responses['AT+MTSM=1']
            $status.Rssnr = ConvertFrom-XcesqResponse $Responses['AT+XCESQ?']
            $status.Ca = ConvertFrom-XlecResponse $Responses['AT+XLEC?']
        }
        'Quectel' {
            $serving = ConvertFrom-QengServingResponse $Responses['AT+QENG="servingcell"']
            $neighbours = ConvertFrom-QengNeighbourResponse $Responses['AT+QENG="neighbourcell"']
            if ($null -ne $serving -or $null -ne $neighbours) { $status.Cells = @(@($serving) + @($neighbours) | Where-Object { $_ }) }
            $status.Neighbors = Get-LteNeighbor $neighbours
            $status.TempC = ConvertFrom-QtempResponse $Responses['AT+QTEMP']
            # QENG's <SINR> scale differs between module families, so SINR comes from QCAINFO / QSINR (dB).
            $ca = ConvertFrom-QcainfoResponse $Responses['AT+QCAINFO']
            $status.Rssnr = if ($null -ne $ca -and $null -ne $ca.PccRssnr) { $ca.PccRssnr } else { ConvertFrom-QsinrResponse $Responses['AT+QSINR'] }
            $status.Ca = if ($null -ne $ca) { [pscustomobject]@{ Cells = $ca.Cells; BandwidthsMHz = $ca.BandwidthsMHz } } else { Get-SingleCarrierCa $serving }
        }
        'FibocomGt' {
            $cells = ConvertFrom-GtccinfoResponse $Responses['AT+GTCCINFO?']
            $status.Cells = $cells
            $status.Neighbors = Get-LteNeighbor $cells
            $lte = @($cells | Where-Object { $_.Rat -eq 'LTE' -and $_.Role -eq 'Serving' } | Select-Object -First 1)
            if ($lte.Count -gt 0) { $status.Rssnr = $lte[0].Rssnr }
            $status.TempC = ConvertFrom-GtsenrdtempResponse $Responses['AT+GTSENRDTEMP=1']
            $ca = ConvertFrom-GtcainfoResponse $Responses['AT+GTCAINFO?']
            $status.Ca = if ($null -ne $ca) { $ca } else { Get-SingleCarrierCa $cells }
        }
    }
    return [pscustomobject]$status
}

# RAT / band configuration from the responses of $AtProfile.Config, or $null:
#   Allowed (e.g. "3G+4G"), Preferred ($null = unknown), GsmBands (MHz), UmtsBands, LteBands, NrBands.
function ConvertFrom-AtConfig($AtProfile, [hashtable]$Responses) {
    switch ($AtProfile.Id) {
        'Intel' { return ConvertFrom-XactResponse $Responses['AT+XACT?'] }
        'Quectel' { return ConvertFrom-QnwprefcfgResponse $Responses }
        'FibocomGt' { return ConvertFrom-GtactResponse $Responses['AT+GTACT?'] }
    }
    return $null
}
