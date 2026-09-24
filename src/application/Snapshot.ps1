# Application: builds modem summary / per-tick snapshot objects (infrastructure + domain).

# Sends one command for startup probing and returns its response ($null = no answer). A timed-out
# command is sent once more: on the L860-GL the AT Tunnel was seen to drop a response right after
# the process starts using it (no retry is needed once running).
function Invoke-AtProbe($Modem, $Channel, [string]$Command) {
    for ($try = 0; $try -lt 2; $try++) {
        $r = (Invoke-ModemAtCommand $Modem $Channel $Command -TimeoutMs 1500)[$Command]
        if ($null -ne $r) { return $r }
    }
    return $null
}

# Finds the AT channel and command set once at startup (a failed detection needs a restart).
# Returns plain data (it crosses into the sampler runspace): @{ Channel; Profile; Error; Tried }
# where Channel / Profile are $null when unavailable, Error is a short reason for the screen and
# Tried lists "<channel>: <reason>" per rejected MBIM service. $AtPort ("COM7") uses that serial
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
        foreach ($atProfile in $script:AtProfiles) {
            if ((Invoke-AtProbe $Modem $at.Channel -Command $atProfile.Probe) -match '(?m)^OK\s*$') { $at.Profile = $atProfile; break }
        }
        # The Intel AT Tunnel only exists on Intel XMM modems: keep the tested command set even when
        # the probe was lost, as before profiles existed (each sample tolerates failed commands).
        if ($null -eq $at.Profile -and $at.Channel.Name -eq 'Intel AT Tunnel') {
            $at.Profile = $script:AtProfiles | Where-Object Id -EQ 'Intel'
        }
        if ($null -eq $at.Profile) { $at.Error = "unsupported AT command set on $($at.Channel.Name)" }
    }
    catch {
        $at.Error = $_.Exception.Message
    }
    return $at
}

function Get-ModemSummary($Modem, [string]$AtPort) {
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
function Get-LteSnapshot($Modem, $At) {
    $snapshot = [pscustomobject]@{
        Timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        ProviderName = ''
        ProviderId   = ''
        DataClass    = ''
        Apn          = ''
        BwMbps       = 0
        RxKB         = 0
        TxKB         = 0
        Serving      = @()
        PrimaryCell  = $null  # Unfiltered first LTE cell, even when RSRP is unavailable.
        Umts         = @()
        # From the AT channel ($null = unavailable; AtError holds the reason when the session failed).
        # Neighbors fall back to WinRT when the AT channel has no neighbor list.
        Neighbors    = $null  # @() = none reported
        TempC        = $null
        Rssnr        = $null  # dB, assuming 0.5 dB steps (unit undocumented)
        Ca           = $null  # @{ Cells; BandwidthsMHz }
        AtError      = $null
        # 2G/3G downgrade check (Get-DowngradeFinding): @{ Level = Alert/Warning/None; Reasons }
        Downgrade    = $null
        Error        = $null
    }

    try {
        $network = $Modem.CurrentNetwork
        $snapshot.ProviderName = "$($network.RegisteredProviderName)"
        $snapshot.ProviderId = "$($network.RegisteredProviderId)"
        $snapshot.DataClass = "$($network.RegisteredDataClass)"
        $snapshot.Apn = "$($network.AccessPointName)"

        $cellsInfo = Get-ModemCellsInfo $network

        $primary = $cellsInfo.ServingCellsLte | Select-Object -First 1
        if ($null -ne $primary) {
            $snapshot.PrimaryCell = [pscustomobject]@{
                Provider = if ($primary.ProviderId) { "$($primary.ProviderId)" } else { $snapshot.ProviderId }
                CellId   = $primary.CellId
                Band     = Get-EarfcnBand $primary.ChannelNumber
                Earfcn   = $primary.ChannelNumber
                Pci      = $primary.PhysicalCellId
                Tac      = $primary.TrackingAreaCode
                RsrpDbm  = ConvertFrom-WinRtRsrp $primary.ReferenceSignalReceivedPowerInDBm
            }
        }

        $traffic = Get-AdapterTraffic
        $snapshot.BwMbps = $traffic.BwMbps
        $snapshot.RxKB = $traffic.RxKB
        $snapshot.TxKB = $traffic.TxKB

        $serving = @()
        foreach ($cell in $cellsInfo.ServingCellsLte) {
            # Raw WinRT values: dBm / dB per the MBIM spec, or 3GPP indices on the L860-GL.
            $rsrpRaw = $cell.ReferenceSignalReceivedPowerInDBm
            $rsrqRaw = $cell.ReferenceSignalReceivedQualityInDBm
            $rsrpDbm = ConvertFrom-WinRtRsrp $rsrpRaw
            if ($null -eq $rsrpDbm) { continue }
            $serving += [pscustomobject]@{
                RsrpDbm  = $rsrpDbm
                RsrpRaw  = $rsrpRaw
                RsrqDb   = ConvertFrom-WinRtRsrq $rsrqRaw
                RsrqRaw  = $rsrqRaw
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

        # WinRT lacks temperature, SINR and CA info (and neighbors on the L860-GL).
        $atCells = $null
        try {
            $status = Get-AtStatus $Modem $At
            foreach ($name in 'Neighbors', 'TempC', 'Rssnr', 'Ca') { $snapshot.$name = $status.$name }
            $atCells = $status.Cells
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
        $snapshot.Downgrade = Get-DowngradeFinding -RegisteredDataClass $snapshot.DataClass `
            -LegacyServingCount $legacyServing -AtCells $atCells -AtSource $At.Profile.Source

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
