# Application: builds modem summary / per-tick snapshot objects (infrastructure + domain).

function Get-ModemSummary($Modem) {
    $devInfo = $Modem.DeviceInformation
    return [pscustomobject]@{
        Model      = "$($devInfo.Model)"
        Firmware   = "$($devInfo.FirmwareInformation)"
        Imei       = "$($devInfo.MobileEquipmentId)"
        SimIccId   = "$($devInfo.SimIccId)"
        SimSpn     = "$($devInfo.SimSpn)"
        RadioState = "$($devInfo.CurrentRadioState)"
        DataClass  = "$($devInfo.DataClasses)"
    }
}

function Get-LteNeighbor($Modem) {
    $response = Invoke-ModemAtCommand $Modem 'AT+XMCI=1'
    if ($response -notmatch '(?m)^OK\s*$') { throw "AT+XMCI failed: $($response.Trim())" }
    $neighbors = @()
    foreach ($cell in (ConvertFrom-XmciResponse $response)) {
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
    return $neighbors
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
        Neighbors     = $null  # $null = unavailable (AT query failed), @() = none reported
        NeighborError = $null
        Umts          = @()
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

        # WinRT reports no neighbors for this modem, so ask it directly with AT+XMCI.
        try {
            $snapshot.Neighbors = Get-LteNeighbor $Modem
        }
        catch {
            $snapshot.NeighborError = $_.Exception.Message
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
