# Hardware-free GPS normalization, sampling, rendering and CSV contract checks.
# Tests call Assert-* with positional arguments and build in-memory fixtures with New-* helpers.
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPositionalParameters', '')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
param()
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/Load.ps1')

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$now = [DateTimeOffset]'2026-09-24T12:00:00Z'
$coordinate = [pscustomobject]@{
    PositionSource = 'Satellite'; IsRemoteSource = $false
    Timestamp = $now; PositionSourceTimestamp = $null
    Point = [pscustomobject]@{
        Position                = [pscustomobject]@{ Latitude = 35.123456; Longitude = 139.123456; Altitude = 0 }
        AltitudeReferenceSystem = 'Ellipsoid'
    }
    Accuracy = 4.5; AltitudeAccuracy = 8; Speed = 0; Heading = 0
    SatelliteData = [pscustomobject]@{ HorizontalDilutionOfPrecision = 1.2; PositionDilutionOfPrecision = 1.9; VerticalDilutionOfPrecision = 1.5 }
}
$reading = [pscustomobject]@{ Status = 'Ready'; Coordinate = $coordinate; Error = $null }
$fix = ConvertFrom-GpsReading $reading -Now $now
Assert-True ($fix.Status -eq 'Fix' -and $fix.Latitude -eq 35.123456 -and $fix.Longitude -eq 139.123456) 'Satellite coordinates lost precision.'
Assert-True ($fix.AltitudeM -eq 0 -and $fix.SpeedMps -eq 0 -and $fix.HeadingDeg -eq 0 -and $fix.Hdop -eq 1.2) 'Valid zero or HDOP was lost.'
Assert-True ($fix.Pdop -eq 1.9 -and $fix.Vdop -eq 1.5) 'PDOP or VDOP was lost.'
Assert-True ($fix.Timestamp -eq '2026-09-24T12:00:00.0000000+00:00') 'GPS time is not UTC.'

foreach ($source in 'WiFi', 'Cellular', 'IPAddress', 'Default', 'Unknown', 'Obfuscated') {
    $coordinate.PositionSource = $source
    $gps = ConvertFrom-GpsReading $reading -Now $now
    Assert-True ($gps.Status -eq 'NoFix' -and $null -eq $gps.Latitude -and $null -eq $gps.Longitude -and $null -eq $gps.Timestamp) "Non-GPS source $source leaked a position."
}
$coordinate.PositionSource = 'Satellite'
$coordinate.IsRemoteSource = $true
$gps = ConvertFrom-GpsReading $reading -Now $now
Assert-True ($gps.Source -eq 'Remote' -and $null -eq $gps.Latitude) 'A remote GPS was labeled as local.'
$coordinate.IsRemoteSource = $false

foreach ($seconds in -16, 6) {
    $coordinate.PositionSourceTimestamp = $now.AddSeconds($seconds)
    $gps = ConvertFrom-GpsReading $reading -Now $now
    Assert-True ($gps.Status -eq 'Stale' -and $null -eq $gps.Latitude) 'Invalid source time was hidden by the recent delivery time.'
}
$coordinate.PositionSourceTimestamp = $null
foreach ($state in 'Disabled', 'NotAvailable', 'NoData', 'Initializing', 'NotInitialized') {
    $reading.Status = $state
    $gps = ConvertFrom-GpsReading $reading -Now $now
    Assert-True ($gps.Status -ne 'Fix' -and $null -eq $gps.Latitude) "State $state retained old coordinates."
}
$reading.Status = 'Ready'
$coordinate.Point.Position.Latitude = 91
Assert-True ((ConvertFrom-GpsReading $reading -Now $now).Status -ne 'Fix') 'Out-of-range latitude accepted.'
$coordinate.Point.Position.Latitude = 0
$coordinate.Point.Position.Longitude = 0
$coordinate.Speed = [double]::NaN
$coordinate.Heading = [double]::PositiveInfinity
$coordinate.Accuracy = -1
$coordinate.AltitudeAccuracy = $null
$coordinate.SatelliteData = $null
$gps = ConvertFrom-GpsReading $reading -Now $now
Assert-True ($gps.Status -eq 'Fix' -and $gps.Latitude -eq 0 -and $gps.Longitude -eq 0) 'Zero coordinates were treated as missing.'
Assert-True ($null -eq $gps.SpeedMps -and $null -eq $gps.HeadingDeg -and $null -eq $gps.AccuracyM -and $null -eq $gps.AltitudeM -and $null -eq $gps.Hdop -and $null -eq $gps.Pdop -and $null -eq $gps.Vdop) 'Unavailable numeric values became zero.'
Assert-True ($null -eq (Get-GpsObservation $null)) 'GPS was queried without opt-in.'
$gps = Get-GpsObservation ([pscustomobject]@{ Client = $null; Error = 'access denied' })
Assert-True ($gps.Status -eq 'Unavailable' -and $gps.Error -eq 'access denied') 'Startup failure was not exposed.'
Write-Output 'PASS: GPS source, freshness, permission, numeric validity and zero/missing distinctions'

# Same receiver crosses the actual sampling runspace; a GPS failure cannot invalidate LTE.
$installFixture = {
    function Get-ModemObservation {
        [pscustomobject]@{ Timestamp = 'test'; Serving = @(); Error = $null }
    }
}
. $installFixture
$receiver = [pscustomobject]@{ Client = $null; Error = 'GPS unavailable' }
$snapshot = Get-LteSnapshot $null $null $receiver
Assert-True ($null -eq $snapshot.Error -and $snapshot.Gps.Error -eq 'GPS unavailable') 'GPS failure invalidated LTE.'
$sampler = New-MonitorSampler
try {
    $null = $sampler.Pipeline.AddScript($installFixture.ToString()).Invoke()
    Start-MonitorSample $sampler $null $null $receiver
    while (-not $sampler.Pending.IsCompleted) { Start-Sleep -Milliseconds 25 }
    $background = Receive-MonitorSample $sampler
    Assert-True ($background.Gps.Error -eq $snapshot.Gps.Error -and $null -eq $background.Error) 'Background GPS contract differs.'
}
finally { Remove-MonitorSampler $sampler }

$session = [pscustomobject]@{
    Config = [pscustomobject]@{ Count = 0; Interval = 0; CsvPath = '' }
    Summary = [pscustomobject]@{ Model = 'Test' }; Snapshot = $snapshot; Iteration = 1
    History = New-SignalHistory; HandoverLog = New-HandoverLog
}
$view = @{ Unicode = $false }
$text = (Get-MonitorFrame $session $view 100).Body.Text -join "`n"
Assert-True ($text -match 'GPS: Unavailable \(GPS unavailable\)') 'GPS failure is missing from the shared TUI/plain frame.'
$snapshot.Gps = $fix
$text = (Get-MonitorFrame $session $view 100).Body.Text -join "`n"
Assert-True ($text -match 'Lat: 35[.,]123456   Lon: 139[.,]123456' -and $text -match 'Source: Satellite' -and
    $text -match 'HDOP: 1[.,]2   PDOP: 1[.,]9   VDOP: 1[.,]5') 'GPS fix is missing from the frame.'
$csvPath = [IO.Path]::GetTempFileName()
try {
    Initialize-SnapshotLog $csvPath
    Add-SnapshotLog $csvPath $snapshot
    $snapshot.Gps = ConvertFrom-GpsReading ([pscustomobject]@{ Status = 'NoData' })
    Add-SnapshotLog $csvPath $snapshot
    $rows = @(Import-Csv -LiteralPath $csvPath)
    Assert-True ($rows[0].GPS_Status -eq 'Fix' -and $rows[0].GPS_Latitude -eq '35.123456' -and $rows[0].GPS_Speed_mps -eq '0') 'GPS CSV fix or units were lost.'
    Assert-True ($rows[1].GPS_Status -eq 'NoFix' -and $rows[1].GPS_Latitude -eq '' -and $rows[1].GPS_Timestamp_UTC -eq '') 'CSV retained stale coordinates.'
}
finally { Remove-Item -LiteralPath $csvPath }
$snapshot.Gps = $null
$text = (Get-MonitorFrame $session $view 100).Body.Text -join "`n"
Assert-True ($text -notmatch 'GPS / GNSS') 'GPS was displayed without opt-in.'
Write-Output 'PASS: GPS failure isolation, real runspace, shared frame and CSV serialization'
