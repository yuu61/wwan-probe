# Domain: AT+XMCI (Measured Cell Information) response parsing (pure, no I/O).
# Fibocom L860-GL AT command manual 9.1.13:
#   TYPE 0/1 (GSM serving/neighbor):  <TYPE>,<MCC>,<MNC>,<LAC>,<CI>,<BSIC>,<RXLEV>,<BER>,<ARFCN>,<TARELIABILITY>,<TA>
#   TYPE 2/3 (UMTS serving/neighbor): <TYPE>,<MCC>,<MNC>,<LAC>,<CI>,<PSC>,<DLUARFCN>,<ULUARFCN>,<PATHLOSS>,<RSSI>,<RSCP>,<ECNO>
#   TYPE 4/5 (LTE serving/neighbor):  <TYPE>,<MCC>,<MNC>,<TAC>,<CI>,<PCI>,<DLEARFCN>,<ULEARFCN>,<PATHLOSS>,<RSRP>,<RSRQ>,<RSSNR>,<TA>,<CQI>
#   (TYPE 6..9 = 1xRTT / EvDO, not supported by this module.) Hex fields are quoted "0x...".
#   LTE RSRP/RSRQ are 3GPP TS 36.133 indices (same scale as the WinRT cell info).

$script:XmciInvalid = [uint32]::MaxValue

function ConvertFrom-XmciHex([string]$text) {
    $text = $text.Trim('"')
    if ($text -notmatch '^0x([0-9A-Fa-f]+)$') { return $null }
    $value = [Convert]::ToUInt32($Matches[1], 16)
    if ($value -eq $script:XmciInvalid) { return $null }
    return $value
}

function ConvertFrom-XmciNumber([string]$text) {
    $text = $text.Trim('"')
    if ($text -match '^0x') { return ConvertFrom-XmciHex $text }
    $n = 0
    if ([int]::TryParse($text, [ref]$n)) { return $n }
    return $null
}

# Returns cells from an AT+XMCI response as [pscustomobject] (the common AT cell shape, see AtProfile.ps1):
#   Rat = GSM/UMTS/LTE, Role = Serving/Neighbor, Channel = ARFCN/UARFCN/EARFCN,
#   and for LTE also Tac, CellId, Pci, Earfcn, RsrpDbm, RsrqDb (and the raw RsrpIdx, RsrqIdx).
function ConvertFrom-XmciResponse([string]$Response) {
    $cells = @()
    foreach ($line in ($Response -split "`r?`n")) {
        if ($line -notmatch '^\+XMCI:\s*(.+)$') { continue }
        $f = $Matches[1] -split ','
        $type = 0
        if (-not [int]::TryParse($f[0], [ref]$type) -or $type -gt 5) { continue }
        $rat = @('GSM', 'UMTS', 'LTE')[[math]::Floor($type / 2)]
        $role = if ($type % 2 -eq 0) { 'Serving' } else { 'Neighbor' }
        $channelIndex = @{ GSM = 8; UMTS = 6; LTE = 6 }[$rat]
        $cell = [ordered]@{
            Rat     = $rat
            Role    = $role
            Channel = if ($f.Count -gt $channelIndex) { ConvertFrom-XmciNumber $f[$channelIndex] } else { $null }
        }
        if ($rat -eq 'LTE') {
            if ($f.Count -lt 14) { continue }
            $cell.Tac = ConvertFrom-XmciHex $f[3]
            $cell.CellId = ConvertFrom-XmciHex $f[4]
            $cell.Pci = ConvertFrom-XmciHex $f[5]
            $cell.Earfcn = ConvertFrom-XmciHex $f[6]
            $cell.RsrpIdx = [int]$f[9]
            $cell.RsrqIdx = [int]$f[10]
            $cell.RsrpDbm = Convert-RsrpIndex $cell.RsrpIdx
            $cell.RsrqDb = Convert-RsrqIndex $cell.RsrqIdx
        }
        $cells += [pscustomobject]$cell
    }
    return $cells
}
