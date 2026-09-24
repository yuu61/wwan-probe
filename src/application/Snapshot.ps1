# Application: builds modem summary / per-tick snapshot objects (infrastructure + domain).

function Get-ModemSummary($Modem) {
    $devInfo = $Modem.DeviceInformation
    # The RAT / band configuration does not change while running, so query it once.
    $ratConfig = $null
    try { $ratConfig = ConvertFrom-XactResponse (Invoke-ModemAtCommand $Modem 'AT+XACT?')['AT+XACT?'] }
    catch { $ratConfig = $null }
    return [pscustomobject]@{
        Model      = "$($devInfo.Model)"
        Firmware   = "$($devInfo.FirmwareInformation)"
        Imei       = "$($devInfo.MobileEquipmentId)"
        SimIccId   = "$($devInfo.SimIccId)"
        SimSpn     = "$($devInfo.SimSpn)"
        RadioState = "$($devInfo.CurrentRadioState)"
        DataClass  = "$($devInfo.DataClasses)"
        RatConfig  = $ratConfig  # ConvertFrom-XactResponse result, $null = unavailable
    }
}

# LTE neighbor cells from ConvertFrom-XmciResponse output ($null when XMCI was unavailable).
function Get-LteNeighbor($XmciCells) {
    if ($null -eq $XmciCells) { return $null }
    $neighbors = @()
    foreach ($cell in $XmciCells) {
        if ($cell.Rat -ne 'LTE' -or $cell.Role -ne 'Neighbor') { continue }
        $rsrpDbm = Convert-RsrpIndex $cell.RsrpIdx
        if ($null -eq $rsrpDbm -or $null -eq $cell.Earfcn) { continue }
        $neighbors += [pscustomobject]@{
            RsrpDbm = $rsrpDbm
            RsrqDb  = Convert-RsrqIndex $cell.RsrqIdx
            Band    = Get-EarfcnBand $cell.Earfcn
            Earfcn  = $cell.Earfcn
            Pci     = $cell.Pci
        }
    }
    return , $neighbors
}

# Values WinRT does not provide, read over the Intel AT Tunnel in one session.
# Each field is $null when its command failed.
function Get-AtStatus($Modem) {
    # XMCI=0 returns the stored measurements immediately; XMCI=1 waits for a fresh serving-cell
    # measurement and was seen to hang for >10 s on a weak cell. It goes last so a timeout
    # only costs the neighbor list.
    $r = Invoke-ModemAtCommand $Modem @('AT+MTSM=1', 'AT+XCESQ?', 'AT+XLEC?', 'AT+XMCI=0')
    $xmci = $r['AT+XMCI=0']
    $xmciCells = if ($xmci -and $xmci -match '(?m)^OK\s*$') { , @(ConvertFrom-XmciResponse $xmci) } else { $null }
    return [pscustomobject]@{
        XmciCells = $xmciCells
        Neighbors = Get-LteNeighbor $xmciCells
        TempC     = ConvertFrom-MtsmResponse $r['AT+MTSM=1']
        Rssnr     = ConvertFrom-XcesqResponse $r['AT+XCESQ?']
        Ca        = ConvertFrom-XlecResponse $r['AT+XLEC?']
    }
}

function Get-LteSnapshot($Modem) {
    $snapshot = [pscustomobject]@{
        Timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ProviderName  = ""
        ProviderId    = ""
        DataClass     = ""
        Apn           = ""
        BwMbps        = 0
        RxKB          = 0
        TxKB          = 0
        Serving       = @()
        Umts          = @()
        # From the AT Tunnel ($null = unavailable; AtError holds the reason when the session failed)
        Neighbors     = $null  # @() = none reported
        TempC         = $null
        Rssnr         = $null  # dB, assuming 0.5 dB steps (unit undocumented)
        Ca            = $null  # @{ Cells; BandwidthsMHz }
        AtError       = $null
        # 2G/3G downgrade check (Get-DowngradeFinding): @{ Level = Alert/Warning/None; Reasons }
        Downgrade     = $null
        Error         = $null
    }

    try {
        $network = $Modem.CurrentNetwork
        $snapshot.ProviderName = "$($network.RegisteredProviderName)"
        $snapshot.ProviderId = "$($network.RegisteredProviderId)"
        $snapshot.DataClass = "$($network.RegisteredDataClass)"
        $snapshot.Apn = "$($network.AccessPointName)"

        $cellsInfo = Get-ModemCellsInfo $network

        $traffic = Get-AdapterTraffic
        $snapshot.BwMbps = $traffic.BwMbps
        $snapshot.RxKB = $traffic.RxKB
        $snapshot.TxKB = $traffic.TxKB

        $serving = @()
        foreach ($cell in $cellsInfo.ServingCellsLte) {
            $rsrpIdx = $cell.ReferenceSignalReceivedPowerInDBm
            $rsrqIdx = $cell.ReferenceSignalReceivedQualityInDBm
            $rsrpDbm = Convert-RsrpIndex $rsrpIdx
            if ($null -eq $rsrpDbm) { continue }
            $serving += [pscustomobject]@{
                RsrpDbm  = $rsrpDbm
                RsrpIdx  = $rsrpIdx
                RsrqDb   = Convert-RsrqIndex $rsrqIdx
                RsrqIdx  = $rsrqIdx
                Quality  = Get-RsrpQuality $rsrpDbm
                Band     = Get-EarfcnBand $cell.ChannelNumber
                Earfcn   = $cell.ChannelNumber
                Pci      = $cell.PhysicalCellId
                CellId   = $cell.CellId
                Tac      = $cell.TrackingAreaCode
                Ta       = $cell.TimingAdvanceInBitPeriods
                Provider = $cell.ProviderId
            }
        }
        $snapshot.Serving = $serving

        # WinRT lacks neighbors, temperature, SINR and CA info for this modem.
        $xmciCells = $null
        try {
            $at = Get-AtStatus $Modem
            foreach ($name in 'Neighbors', 'TempC', 'Rssnr', 'Ca') { $snapshot.$name = $at.$name }
            $xmciCells = $at.XmciCells
        }
        catch {
            $snapshot.AtError = $_.Exception.Message
        }

        $legacyServing = 0
        foreach ($list in $cellsInfo.ServingCellsGsm, $cellsInfo.ServingCellsUmts, $cellsInfo.ServingCellsTdscdma, $cellsInfo.ServingCellsCdma) {
            $legacyServing += @($list | Where-Object { $_ }).Count
        }
        $snapshot.Downgrade = Get-DowngradeFinding -RegisteredDataClass $snapshot.DataClass `
            -LegacyServingCount $legacyServing -XmciCells $xmciCells

        $umts = @()
        foreach ($cell in $cellsInfo.ServingCellsUmts) {
            $umts += [pscustomobject]@{
                CellId  = $cell.CellId
                Uarfcn  = $cell.ChannelNumber
                RscpDbm = $cell.ReceivedSignalCodePowerInDBm
            }
        }
        $snapshot.Umts = $umts
    }
    catch {
        $snapshot.Error = $_.Exception.Message
    }

    return $snapshot
}
