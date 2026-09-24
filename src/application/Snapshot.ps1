# Application: builds modem summary / per-tick snapshot objects (infrastructure + domain).

function Get-ModemSummary($Modem) {
    $devInfo = $Modem.DeviceInformation
    # Enabled LTE bands do not change while running, so query them once.
    $lteBands = $null
    try { $lteBands = ConvertFrom-XactResponse (Invoke-ModemAtCommand $Modem 'AT+XACT?')['AT+XACT?'] }
    catch { $lteBands = $null }
    return [pscustomobject]@{
        Model      = "$($devInfo.Model)"
        Firmware   = "$($devInfo.FirmwareInformation)"
        Imei       = "$($devInfo.MobileEquipmentId)"
        SimIccId   = "$($devInfo.SimIccId)"
        SimSpn     = "$($devInfo.SimSpn)"
        RadioState = "$($devInfo.CurrentRadioState)"
        DataClass  = "$($devInfo.DataClasses)"
        LteBands   = $lteBands  # $null = unavailable
    }
}

# LTE neighbor cells from an AT+XMCI response ($null when the command failed).
function Get-LteNeighbor([string]$Response) {
    if (-not $Response -or $Response -notmatch '(?m)^OK\s*$') { return $null }
    $neighbors = @()
    foreach ($cell in (ConvertFrom-XmciResponse $Response)) {
        if ($cell.Type -ne 'Neighbor') { continue }
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
    return [pscustomobject]@{
        Neighbors = Get-LteNeighbor $r['AT+XMCI=0']
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
        Rssnr         = $null  # raw value, unit undocumented
        Ca            = $null  # @{ Cells; BandwidthsMHz }
        AtError       = $null
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
        try {
            $at = Get-AtStatus $Modem
            foreach ($name in 'Neighbors', 'TempC', 'Rssnr', 'Ca') { $snapshot.$name = $at.$name }
        }
        catch {
            $snapshot.AtError = $_.Exception.Message
        }

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
