# Infrastructure: Windows GNSS reports. Accept only local satellite fixes; Windows
# may also return Wi-Fi/cellular/IP positions, which must not be presented as GPS.
# Geolocator cannot select a particular modem or identify the physical GPS receiver.

function Start-GpsReceiver {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    $receiver = [pscustomobject]@{ Client = $null; Error = $null }
    try {
        if (-not ('WwanProbe.GpsReceiver' -as [type])) {
            $references = @(
                'System.Threading.dll'
                [Windows.Devices.Geolocation.Geolocator].Assembly.Location
                [WinRT.IWinRTObject].Assembly.Location
            )
            # setup.ps1 targets .NET 8; newer PowerShell releases unify those references.
            Add-Type -Path (Join-Path $PSScriptRoot 'GpsReceiver.cs') -ReferencedAssemblies $references `
                -CompilerOptions '/nowarn:1701,1702' -ErrorAction Stop
        }
        $receiver.Client = [WwanProbe.GpsReceiver]::new()
    }
    catch { $receiver.Error = $_.Exception.Message }
    return $receiver
}

function Stop-GpsReceiver {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Receiver)

    if ($null -ne $Receiver.Client) { $Receiver.Client.Dispose() }
}

function ConvertTo-GpsNumber($Value, [double]$Min = [double]::NegativeInfinity, [double]$Max = [double]::PositiveInfinity) {
    if ($null -eq $Value) { return $null }
    $number = [double]$Value
    if (-not [double]::IsFinite($number) -or $number -lt $Min -or $number -gt $Max) { return $null }
    return $number
}

# Pure normalization, also used by hardware-free tests. No stale coordinates are
# retained after a source change, loss of permission, or a report older than 15 s.
function ConvertFrom-GpsReading($Reading, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow) {
    $gps = [pscustomobject]@{
        Status = 'NoFix'; Source = ''; Timestamp = $null
        Latitude = $null; Longitude = $null; AltitudeM = $null; AccuracyM = $null
        SpeedMps = $null; HeadingDeg = $null; Hdop = $null; Pdop = $null; Vdop = $null; Error = $null
    }
    if ($Reading.Error) {
        $gps.Status = 'Unavailable'
        $gps.Error = $Reading.Error
        return $gps
    }
    switch ($Reading.Status) {
        'Disabled' { $gps.Status = 'Disabled'; $gps.Error = 'Enable Windows location services and desktop app location access'; return $gps }
        'NotAvailable' { $gps.Status = 'Unavailable'; $gps.Error = 'No Windows location provider available'; return $gps }
        'NoData' { return $gps }
        'Initializing' { return $gps }
        'NotInitialized' { return $gps }
    }
    $c = $Reading.Coordinate
    if ($null -eq $c) { return $gps }
    $gps.Source = "$($c.PositionSource)"
    if ($c.IsRemoteSource) { $gps.Source = 'Remote'; return $gps }
    if ($gps.Source -ne 'Satellite') { return $gps }
    $timestamp = if ($null -ne $c.PositionSourceTimestamp) { $c.PositionSourceTimestamp } else { $c.Timestamp }
    if ($null -eq $timestamp) { return $gps }
    $age = ($Now - [DateTimeOffset]$timestamp).TotalSeconds
    if ($age -gt 15 -or $age -lt -5) { $gps.Status = 'Stale'; return $gps }
    $latitude = ConvertTo-GpsNumber $c.Point.Position.Latitude -Min -90 -Max 90
    $longitude = ConvertTo-GpsNumber $c.Point.Position.Longitude -Min -180 -Max 180
    if ($null -eq $latitude -or $null -eq $longitude) { return $gps }
    $gps.Status = 'Fix'
    $gps.Timestamp = ([DateTimeOffset]$timestamp).ToUniversalTime().ToString('o')
    $gps.Latitude = $latitude
    $gps.Longitude = $longitude
    # Unknown altitude reference or missing vertical accuracy must not turn into 0 m.
    if ($c.Point.AltitudeReferenceSystem -and "$($c.Point.AltitudeReferenceSystem)" -ne 'Unspecified' -and
        $null -ne (ConvertTo-GpsNumber $c.AltitudeAccuracy -Min 0)) {
        $gps.AltitudeM = ConvertTo-GpsNumber $c.Point.Position.Altitude
    }
    $gps.AccuracyM = ConvertTo-GpsNumber $c.Accuracy -Min 0
    $gps.SpeedMps = ConvertTo-GpsNumber $c.Speed -Min 0
    $gps.HeadingDeg = ConvertTo-GpsNumber $c.Heading -Min 0 -Max 360
    $gps.Hdop = ConvertTo-GpsNumber $c.SatelliteData.HorizontalDilutionOfPrecision -Min 0
    $gps.Pdop = ConvertTo-GpsNumber $c.SatelliteData.PositionDilutionOfPrecision -Min 0
    $gps.Vdop = ConvertTo-GpsNumber $c.SatelliteData.VerticalDilutionOfPrecision -Min 0
    return $gps
}

function Get-GpsObservation($Receiver) {
    if ($null -eq $Receiver) { return $null }
    try {
        $reading = if ($Receiver.Error) { $Receiver } else { $Receiver.Client.Read() }
        return ConvertFrom-GpsReading $reading
    }
    catch { return ConvertFrom-GpsReading ([pscustomobject]@{ Error = $_.Exception.Message }) }
}
