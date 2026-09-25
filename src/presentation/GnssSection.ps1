# Presentation: GPS / GNSS section on the main screen and the satellite list ([s] view).

# $Satellites: Get-NmeaObservation (Status; Error; InView; Used; Systems; NmeaReceived).
function Format-SatelliteSummary($Satellites) {
    switch ($Satellites.Status) {
        'Starting' { return 'Starting (waiting for the elevated NMEA helper)' }
        'Stale' { return 'Stale (the NMEA helper stopped updating)' }
        'Unavailable' { return "Unavailable ($($Satellites.Error))" }
    }
    if (-not $Satellites.NmeaReceived) { return 'waiting for NMEA from the GNSS driver' }
    $systems = @($Satellites.Systems.Keys | ForEach-Object { "$_ $($Satellites.Systems[$_].InView)" }) -join ', '
    if ($systems) { $systems = " ($systems)" }
    return "$($Satellites.InView) in view$systems, $($Satellites.Used) used"
}

# $Fix: the receiver's fix state from NMEA (Nmea.ps1); values not received recently are n/a.
function Add-NmeaFixLine([System.Collections.Generic.List[object]]$Lines, $Fix) {
    if ($null -eq $Fix) { return }
    $status = if ($null -eq $Fix.Valid) { 'n/a' } elseif ($Fix.Valid) { 'valid' } else { 'invalid' }
    $color = if ($Fix.Valid -eq $false -or $Fix.Dimension -eq 'NoFix') { 'DarkYellow' } else { 'Gray' }
    $Lines.Add((New-FrameLine (' Fix (NMEA): {0}   Quality: {1}   Mode: {2} ({3})   Sats used: {4}' -f
                (Format-OptionalValue $Fix.Dimension '{0}'), (Format-OptionalValue $Fix.Quality '{0}'),
                (Format-OptionalValue $Fix.Mode '{0}'), $status, (Format-OptionalValue $Fix.SatellitesUsed '{0}')) $color))
    $Lines.Add((New-FrameLine (' Altitude MSL: {0}   Geoid separation: {1}' -f
                (Format-OptionalValue $Fix.AltitudeMslM '{0:0.0} m'), (Format-OptionalValue $Fix.GeoidSeparationM '{0:0.0} m')) $color))
}

function Add-GpsSection([System.Collections.Generic.List[object]]$Lines, $Gps, $Satellites, [int]$Width) {
    if ($null -eq $Gps -and $null -eq $Satellites) { return }
    $Lines.Add((New-FrameLine (Get-SectionRule 'GPS / GNSS' $Width) 'DarkCyan'))
    if ($Gps.Status -eq 'Fix') {
        $Lines.Add((New-FrameLine (' Lat: {0:F6}   Lon: {1:F6}   Accuracy: {2}' -f
                    $Gps.Latitude, $Gps.Longitude, (Format-OptionalValue $Gps.AccuracyM '{0:0.0} m')) 'Green'))
        $Lines.Add((New-FrameLine (' Alt: {0}   Speed: {1}   Heading: {2}' -f
                    (Format-OptionalValue $Gps.AltitudeM '{0:0.0} m'), (Format-OptionalValue $Gps.SpeedMps '{0:0.0} m/s'),
                    (Format-OptionalValue $Gps.HeadingDeg '{0:0.0} deg'))))
        $Lines.Add((New-FrameLine (' HDOP: {0}   PDOP: {1}   VDOP: {2}' -f (Format-OptionalValue $Gps.Hdop '{0:0.0}'),
                    (Format-OptionalValue $Gps.Pdop '{0:0.0}'), (Format-OptionalValue $Gps.Vdop '{0:0.0}'))))
        $Lines.Add((New-FrameLine " Source: Satellite   Fix UTC: $($Gps.Timestamp)" 'DarkGray'))
    }
    elseif ($null -ne $Gps) {
        $detail = switch ($Gps.Status) {
            'Disabled' { $Gps.Error }
            'Unavailable' { $Gps.Error }
            'Stale' { 'satellite report expired; waiting for a fresh fix' }
            default { if ($Gps.Source) { "waiting for satellite fix; $($Gps.Source) position ignored" } else { 'waiting for satellite fix' } }
        }
        $Lines.Add((New-FrameLine " GPS: $($Gps.Status) ($detail)" 'DarkYellow'))
    }
    if ($null -ne $Satellites) {
        $color = if ($Satellites.Status -eq 'Receiving') { 'Gray' } else { 'DarkYellow' }
        $Lines.Add((New-FrameLine " Satellites: $(Format-SatelliteSummary $Satellites)  [s]" $color))
        if ($Satellites.Status -eq 'Receiving') { Add-NmeaFixLine $Lines $Satellites.Fix }
    }
}

$script:SatelliteSystemColors = @{
    GPS = 'Green'; QZSS = 'White'; SBAS = 'Gray'; GLONASS = 'Magenta'
    Galileo = 'Cyan'; BeiDou = 'Yellow'; NavIC = 'DarkMagenta'; Unknown = 'DarkGray'
}

# Satellite list (the [s] view): one row per satellite and signal, colored by constellation.
# $Satellites = $null means -Nmea is off ($Enabled = $false) or no sample has completed yet.
function Add-SatelliteSection {
    param([System.Collections.Generic.List[object]]$Lines, $Satellites, [bool]$Enabled, [hashtable]$View, [int]$Width)

    $Lines.Add((New-FrameLine (Get-SectionRule 'Satellites (NMEA GSV/GSA) [s]' $Width) 'DarkCyan'))
    if (-not $Enabled) {
        $Lines.Add((New-FrameLine ' (satellite list is off: start lte_monitor.ps1 with -Nmea)' 'DarkGray'))
        return
    }
    if ($null -eq $Satellites) {
        $Lines.Add((New-FrameLine ' Waiting for first sample...' 'DarkGray'))
        return
    }
    $summary = Format-SatelliteSummary $Satellites
    if ($Satellites.Status -ne 'Receiving' -or @($Satellites.Satellites).Count -eq 0) {
        $Lines.Add((New-FrameLine " $summary" $(if ($Satellites.Status -eq 'Receiving') { 'DarkGray' } else { 'DarkYellow' })))
        if ($Satellites.Status -eq 'Receiving') { Add-NmeaFixLine $Lines $Satellites.Fix }
        return
    }
    $Lines.Add((New-FrameLine " $summary   Updated: $($Satellites.UpdatedUtc)" 'DarkGray'))
    Add-NmeaFixLine $Lines $Satellites.Fix
    $Lines.Add((New-FrameLine ' System     ID  Sig  Elev  Azim  SNR  Used  C/N0 (0-50 dB-Hz)' 'DarkGray'))
    $rows = @($Satellites.Satellites)
    $height = if ($View.LastHeight -gt 0) { $View.LastHeight } else { 30 }
    # Title, rule, optional downgrade warning, section title, summary, two fix lines, header,
    # scroll line and footer.
    $pageSize = [math]::Max(1, $height - 10)
    $offset = [math]::Clamp([int]$View.SatelliteOffset, 0, [math]::Max(0, $rows.Count - $pageSize))
    $View.SatelliteOffset = $offset
    foreach ($s in ($rows | Select-Object -Skip $offset -First $pageSize)) {
        $text = ' {0,-8} {1,4} {2,4} {3,5} {4,5} {5,4}  {6,-4}  {7}' -f $s.System, $s.Id, $s.Signal,
        (Format-OptionalValue $s.ElevationDeg '{0}'), (Format-OptionalValue $s.AzimuthDeg '{0}'),
        (Format-OptionalValue $s.SnrDbHz '{0}'), $(if ($s.Used) { 'yes' } else { '' }), (Get-SnrBar $s.SnrDbHz)
        $color = $script:SatelliteSystemColors[[string]$s.System]
        $Lines.Add((New-FrameLine $text $(if ($color) { $color } else { 'DarkGray' })))
    }
    if ($rows.Count -gt $pageSize) {
        $Lines.Add((New-FrameLine (' Rows {0}-{1} / {2}  [Up/Down] scroll' -f ($offset + 1), [math]::Min($rows.Count, $offset + $pageSize), $rows.Count) 'DarkGray'))
    }
}
