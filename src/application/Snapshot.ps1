# Application: apply monitoring rules to normalized infrastructure observations.

function Get-ModemSummary($Modem, [string]$AtPort) {
    $summary = Get-ModemDeviceSummary $Modem $AtPort
    $summary | Add-Member -NotePropertyName LegacyAllowed -NotePropertyValue (Test-LegacyRatAllowed $summary.RatConfig.AllowedRats)
    return $summary
}

# Serving preserves every LTE serving cell in device order, even without signal values.
# PrimaryCell is selected once; SecondaryCells contains the remaining carriers.
# All consumers use these roles instead of selecting by measurement availability.
# Missing values stay $null; Error, AtError and TrafficError identify failed sources.
# Gps / Satellites are $null unless -Gps / -Nmea started their receivers.
function Get-LteSnapshot($Modem, $At, $GpsReceiver, $NmeaReceiver) {
    $observation = Get-ModemObservation $Modem $At
    $serving = @($observation.Serving)
    foreach ($cell in $serving) {
        $cell | Add-Member -NotePropertyName Quality -NotePropertyValue (Get-RsrpQuality $cell.RsrpDbm)
    }
    $snapshot = [pscustomobject]@{
        Timestamp      = $observation.Timestamp
        ProviderName   = $observation.ProviderName
        ProviderId     = $observation.ProviderId
        DataClass      = $observation.DataClass
        Apn            = $observation.Apn
        BwMbps         = $observation.BwMbps
        RxKB           = $observation.RxKB
        TxKB           = $observation.TxKB
        Serving        = $serving
        PrimaryCell    = $serving | Select-Object -First 1
        SecondaryCells = @($serving | Select-Object -Skip 1)
        Umts           = $observation.Umts
        Neighbors      = $observation.Neighbors
        TempC          = $observation.TempC
        Rssnr          = $observation.Rssnr
        Ca             = $observation.Ca
        Error          = $observation.Error
        AtError        = $observation.AtError
        TrafficError   = $observation.TrafficError
        Gps            = Get-GpsObservation $GpsReceiver
        Satellites     = Get-NmeaObservation $NmeaReceiver
        Downgrade      = $null
    }
    if (-not $observation.Error) {
        $snapshot.Downgrade = Get-DowngradeFinding -RegisteredRats $observation.RegisteredRats `
            -LegacyServingCount $observation.LegacyServingCount -AtCells $observation.AtCells -AtSource $observation.AtSource
    }
    return $snapshot
}
