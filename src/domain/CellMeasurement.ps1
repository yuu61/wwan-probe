# Domain: AT+XMCI (Measured Cell Information) response parsing (pure, no I/O).
# Fibocom L860-GL AT command manual, LTE records:
#   +XMCI: <TYPE>,<MCC>,<MNC>,<TAC>,<CI>,<PCI>,<DLEARFCN>,<ULEARFCN>,<PATHLOSS>,<RSRP>,<RSRQ>,<RSSNR>,<TA>,<CQI>
#   TYPE 4 = LTE serving cell, 5 = LTE neighbor cell. Hex fields are quoted "0x...".
#   RSRP/RSRQ are 3GPP TS 36.133 indices (same scale as the WinRT cell info).

$script:XmciInvalid = [uint32]::MaxValue

function ConvertFrom-XmciHex([string]$text) {
    $text = $text.Trim('"')
    if ($text -notmatch '^0x([0-9A-Fa-f]+)$') { return $null }
    $value = [Convert]::ToUInt32($Matches[1], 16)
    if ($value -eq $script:XmciInvalid) { return $null }
    return $value
}

# Returns LTE cells ([pscustomobject] with Type = Serving/Neighbor) from an AT+XMCI=1 response.
function ConvertFrom-XmciResponse([string]$Response) {
    $cells = @()
    foreach ($line in ($Response -split "`r?`n")) {
        if ($line -notmatch '^\+XMCI:\s*(.+)$') { continue }
        $f = $Matches[1] -split ','
        if ($f.Count -lt 14) { continue }
        $type = switch ($f[0]) { '4' { 'Serving' } '5' { 'Neighbor' } default { $null } }
        if (-not $type) { continue }
        $cells += [pscustomobject]@{
            Type    = $type
            Tac     = ConvertFrom-XmciHex $f[3]
            CellId  = ConvertFrom-XmciHex $f[4]
            Pci     = ConvertFrom-XmciHex $f[5]
            Earfcn  = ConvertFrom-XmciHex $f[6]
            RsrpIdx = [int]$f[9]
            RsrqIdx = [int]$f[10]
        }
    }
    return $cells
}
