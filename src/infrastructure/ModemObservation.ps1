# Infrastructure: modem discovery and normalized observations from WinRT and AT.

# Normalize WinRT enum flags before passing them to monitoring rules.
function ConvertFrom-WinRtDataClass([string]$DataClass) {
    $names = @{
        Gprs = 'GSM'; Edge = 'GSM'; Umts = 'UMTS'; Hsdpa = 'UMTS'; Hsupa = 'UMTS'
        Cdma1xRtt = 'CDMA'; Cdma1xEvdo = 'CDMA'; Cdma1xEvdoRevA = 'CDMA'
        Cdma1xEvdv = 'CDMA'; Cdma3xRtt = 'CDMA'; Cdma1xEvdoRevB = 'CDMA'; CdmaUmb = 'CDMA'
        Lte = 'LTE'; NewRadioNonStandalone = 'NR'; NewRadioStandalone = 'NR'
    }
    return , @($DataClass -split ',' | ForEach-Object { $names[$_.Trim()] } | Where-Object { $_ } | Select-Object -Unique)
}

# Finds the AT channel and command set once at startup (a failed detection needs a restart).
# Returns plain data (it crosses into the sampler runspace): @{ Channel; Profile; Error; Tried }
# where Channel / Profile are $null when unavailable, Error is a short reason for the screen and
# Tried lists "<channel>: <reason>" per MBIM service that did not answer OK. $AtPort ("COM7") uses that serial
# port instead of the MBIM services.
function Initialize-ModemAt($Modem, [string]$AtPort) {
    $at = [pscustomobject]@{ Channel = $null; Profile = $null; Error = $null; Tried = @() }
    try {
        if ($AtPort) {
            $channel = New-SerialAtChannel $AtPort
            if ((Invoke-AtProbe $Modem $channel -Command 'AT') -notmatch '(?m)^OK\s*$') { throw "no AT response on $AtPort" }
            $at.Channel = $channel
        }
        else {
            $tried = [System.Collections.Generic.List[string]]::new()
            $at.Channel = Find-ModemAtChannel $Modem $tried
            $at.Tried = @($tried)
            if ($null -eq $at.Channel) { throw "no AT channel ($($tried.Count) MBIM services tried)" }
        }
        # A channel that did not answer "AT" (Find-ModemAtChannel fallback) would not answer the
        # probes either, so it goes straight to the command set its service implies.
        if (-not $at.Channel.Unconfirmed) {
            foreach ($atProfile in $script:AtProfiles) {
                if ((Invoke-AtProbe $Modem $at.Channel -Command $atProfile.Probe) -match '(?m)^OK\s*$') { $at.Profile = $atProfile; break }
            }
        }
        # A service that exists on one chipset only (the Intel AT Tunnel) keeps its tested command set
        # even when the probe was lost, as before profiles existed (each sample tolerates failed commands).
        if ($null -eq $at.Profile -and $at.Channel.Profile) {
            $at.Profile = $script:AtProfiles | Where-Object Id -EQ $at.Channel.Profile
        }
        if ($null -eq $at.Profile) { $at.Error = "unsupported AT command set on $($at.Channel.Name)" }
    }
    catch {
        $at.Error = $_.Exception.Message
    }
    return $at
}

function Get-ModemDeviceSummary($Modem, [string]$AtPort) {
    $devInfo = $Modem.DeviceInformation
    $at = Initialize-ModemAt $Modem $AtPort
    # The RAT / band configuration does not change while running, so query it once.
    $ratConfig = $null
    if ($at.Profile) {
        try { $ratConfig = ConvertFrom-AtConfig $at.Profile (Invoke-ModemAtCommand $Modem $at.Channel $at.Profile.Config) }
        catch { $ratConfig = $null }
    }
    return [pscustomobject]@{
        Model        = "$($devInfo.Model)"
        Manufacturer = "$($devInfo.Manufacturer)"
        Firmware     = "$($devInfo.FirmwareInformation)"
        Imei         = "$($devInfo.MobileEquipmentId)"
        SimIccId     = "$($devInfo.SimIccId)"
        SimSpn       = "$($devInfo.SimSpn)"
        RadioState   = "$($devInfo.CurrentRadioState)"
        DataClass    = "$($devInfo.DataClasses)"
        At           = $at         # Initialize-ModemAt result
        RatConfig    = $ratConfig  # ConvertFrom-AtConfig result, $null = unavailable
    }
}

# LTE neighbor cells reported by WinRT (MBIM_CID_BASE_STATIONS_INFO), or $null when there are none.
# Returning none is allowed by the spec (the L860-GL never reports any), so an empty list is
# treated as "unavailable" and does not hide the AT error.
function Get-WinRtLteNeighbor($Cells) {
    $neighbors = @()
    foreach ($cell in @($Cells | Where-Object { $_ })) {
        $rsrpDbm = ConvertFrom-WinRtRsrp $cell.ReferenceSignalReceivedPowerInDBm
        if ($null -eq $rsrpDbm -or $null -eq $cell.ChannelNumber) { continue }
        $neighbors += [pscustomobject]@{
            RsrpDbm = $rsrpDbm
            RsrqDb  = ConvertFrom-WinRtRsrq $cell.ReferenceSignalReceivedQualityInDBm
            Band    = Get-EarfcnBand $cell.ChannelNumber
            Earfcn  = $cell.ChannelNumber
            Pci     = $cell.PhysicalCellId
        }
    }
    if ($neighbors.Count -eq 0) { return $null }
    return , $neighbors
}

# Values WinRT does not provide, read over the AT channel in one session (ConvertFrom-AtStatus result).
function Get-AtStatus($Modem, $At) {
    if ($null -eq $At -or $null -eq $At.Profile) { throw $(if ($At.Error) { $At.Error } else { 'AT not initialized' }) }
    $r = Invoke-ModemAtCommand $Modem $At.Channel $At.Profile.Status
    return ConvertFrom-AtStatus $At.Profile $r
}

# $At: Summary.At (Initialize-ModemAt); $null skips the AT values.
function Get-ModemObservation($Modem, $At) {
    $snapshot = [pscustomobject]@{
        Timestamp          = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        ProviderName       = ''
        ProviderId         = ''
        DataClass          = ''
        RegisteredRats     = @()
        Apn                = ''
        BwMbps             = $null
        RxKB               = $null
        TxKB               = $null
        Serving            = @()
        Umts               = @()
        # From the AT channel ($null = unavailable; AtError holds the reason when the session failed).
        # Neighbors fall back to WinRT when the AT channel has no neighbor list.
        Neighbors          = $null  # @() = none reported
        TempC              = $null
        Rssnr              = $null  # dB, assuming 0.5 dB steps (unit undocumented)
        Ca                 = $null  # @{ Cells; BandwidthsMHz }
        AtError            = $null
        TrafficError       = $null
        LegacyServingCount = 0
        AtCells            = $null
        AtSource           = $At.Profile.Source
        Error              = $null
    }

    try {
        $network = $Modem.CurrentNetwork
        $snapshot.ProviderName = "$($network.RegisteredProviderName)"
        $snapshot.ProviderId = "$($network.RegisteredProviderId)"
        $snapshot.DataClass = "$($network.RegisteredDataClass)"
        $snapshot.RegisteredRats = ConvertFrom-WinRtDataClass $snapshot.DataClass
        $snapshot.Apn = "$($network.AccessPointName)"

        $cellsInfo = Get-ModemCellsInfo $network

        $traffic = Get-AdapterTraffic
        $snapshot.BwMbps = $traffic.BwMbps
        $snapshot.RxKB = $traffic.RxKB
        $snapshot.TxKB = $traffic.TxKB
        $snapshot.TrafficError = $traffic.Error

        $serving = @()
        foreach ($cell in $cellsInfo.ServingCellsLte) {
            # Raw WinRT values: dBm / dB per the MBIM spec, or 3GPP indices on the L860-GL.
            $rsrpRaw = $cell.ReferenceSignalReceivedPowerInDBm
            $rsrqRaw = $cell.ReferenceSignalReceivedQualityInDBm
            $rsrpDbm = ConvertFrom-WinRtRsrp $rsrpRaw
            $serving += [pscustomobject]@{
                RsrpDbm  = $rsrpDbm
                RsrpRaw  = $rsrpRaw
                RsrqDb   = ConvertFrom-WinRtRsrq $rsrqRaw
                RsrqRaw  = $rsrqRaw
                Band     = Get-EarfcnBand $cell.ChannelNumber
                Earfcn   = $cell.ChannelNumber
                Pci      = $cell.PhysicalCellId
                CellId   = $cell.CellId
                Tac      = $cell.TrackingAreaCode
                Ta       = $cell.TimingAdvanceInBitPeriods
                Provider = if ($cell.ProviderId) { "$($cell.ProviderId)" } else { $snapshot.ProviderId }
            }
        }
        $snapshot.Serving = $serving

        # WinRT lacks temperature, SINR and CA info (and neighbors on the L860-GL).
        try {
            $status = Get-AtStatus $Modem $At
            foreach ($name in 'Neighbors', 'TempC', 'Rssnr', 'Ca') { $snapshot.$name = $status.$name }
            $snapshot.AtCells = $status.Cells
        }
        catch {
            $snapshot.AtError = $_.Exception.Message
        }
        if ($null -eq $snapshot.Neighbors) {
            $snapshot.Neighbors = Get-WinRtLteNeighbor $cellsInfo.NeighboringCellsLte
        }

        $legacyServing = 0
        foreach ($list in $cellsInfo.ServingCellsGsm, $cellsInfo.ServingCellsUmts, $cellsInfo.ServingCellsTdscdma, $cellsInfo.ServingCellsCdma) {
            $legacyServing += @($list | Where-Object { $_ }).Count
        }
        $snapshot.LegacyServingCount = $legacyServing

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
