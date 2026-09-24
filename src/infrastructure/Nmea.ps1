# Infrastructure: NMEA 0183 satellite sentences (GSV = satellites in view, GSA = used in
# the fix). Pure parsing, also used by hardware-free tests. Position sentences (GGA, RMC)
# are never kept, so satellite reports carry no coordinates.
#
# Satellite: @{ System; Id; Signal; ElevationDeg; AzimuthDeg; SnrDbHz; Used }
#   Id is the NMEA ID as reported (GLONASS 65-96 in GP/GN and GL sentences alike);
#   Signal is the NMEA 4.10 signal ID ('' before 4.10); missing values are $null.

# GSA system ID (NMEA 4.10) -> talker of that constellation.
$script:NmeaSystemTalkers = @{ '1' = 'GP'; '2' = 'GL'; '3' = 'GA'; '4' = 'GB'; '5' = 'GQ'; '6' = 'GI' }
$script:NmeaTalkerSystems = @{ GL = 'GLONASS'; GA = 'Galileo'; GB = 'BeiDou'; BD = 'BeiDou'; GQ = 'QZSS'; QZ = 'QZSS'; GI = 'NavIC' }
# Display order of the constellations.
$script:NmeaSystems = @('GPS', 'QZSS', 'SBAS', 'GLONASS', 'Galileo', 'BeiDou', 'NavIC', 'Unknown')

# Constellation of satellite $Id. GP/GN talkers mix systems, told apart by the NMEA ID ranges.
function Get-NmeaSatelliteSystem([string]$Talker, [int]$Id) {
    if ($script:NmeaTalkerSystems.ContainsKey($Talker)) { return $script:NmeaTalkerSystems[$Talker] }
    if ($Id -ge 1 -and $Id -le 32) { return 'GPS' }
    if (($Id -ge 33 -and $Id -le 64) -or ($Id -ge 120 -and $Id -le 158)) { return 'SBAS' }
    if ($Id -ge 65 -and $Id -le 96) { return 'GLONASS' }
    if ($Id -ge 193 -and $Id -le 202) { return 'QZSS' }
    return 'Unknown'
}

function ConvertFrom-NmeaInteger([string]$Text, [int]$Min, [int]$Max) {
    $value = 0
    if (-not [int]::TryParse($Text, [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    if ($value -lt $Min -or $value -gt $Max) { return $null }
    return $value
}

# Complete, checksum-valid sentences ('$...*hh') in $Buffer, a stream whose sentences can
# span driver events. Rest is the incomplete tail to prepend to the next chunk.
function Split-NmeaStream([string]$Buffer) {
    $sentences = [Collections.Generic.List[string]]::new()
    $end = 0
    foreach ($match in [regex]::Matches($Buffer, '\$([^$*\r\n]+)\*([0-9A-Fa-f]{2})')) {
        $end = $match.Index + $match.Length
        $checksum = 0
        foreach ($character in $match.Groups[1].Value.ToCharArray()) { $checksum = $checksum -bxor [int]$character }
        if ($checksum -eq [Convert]::ToInt32($match.Groups[2].Value, 16)) { $sentences.Add($match.Value) }
    }
    $rest = $Buffer.Substring($end)
    $start = $rest.LastIndexOf('$')
    # A tail without '$' is noise; an overlong one is corrupt (sentences are <= 82 chars).
    $rest = if ($start -lt 0 -or $rest.Length - $start -gt 256) { '' } else { $rest.Substring($start) }
    return [pscustomobject]@{ Sentences = $sentences.ToArray(); Rest = $rest }
}

function New-NmeaSatelliteState {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    # Views / Pending: GSV cycles per talker and signal; Used: GSA per talker and system ID.
    return [pscustomobject]@{ Views = @{}; Pending = @{}; Used = @{} }
}

# Applies one checksum-valid sentence received at $Now. A GSV cycle (message 1..N) replaces
# the previous one only when complete and in order; other sentence types are ignored.
function Add-NmeaSentence($State, [string]$Sentence, [DateTimeOffset]$Now) {
    $fields = $Sentence.Substring(1, $Sentence.LastIndexOf('*') - 1).Split(',')
    if ($fields[0] -notmatch '^(?<talker>[A-Z]{2})(?<type>GSV|GSA)$') { return }
    $talker = $Matches.talker
    if ($Matches.type -eq 'GSA') {
        if ($fields.Length -lt 18) { return }
        $systemId = if ($fields.Length -gt 18) { $fields[18] } else { '' }
        $systemTalker = if ($script:NmeaSystemTalkers.ContainsKey($systemId)) { $script:NmeaSystemTalkers[$systemId] } else { $talker }
        $keys = @($fields[3..14] | ForEach-Object { ConvertFrom-NmeaInteger $_ -Min 1 -Max 999 } | Where-Object { $null -ne $_ } |
                ForEach-Object { "$(Get-NmeaSatelliteSystem $systemTalker $_):$_" })
        $State.Used["${talker}:$systemId"] = [pscustomobject]@{ Received = $Now; Keys = $keys }
        return
    }
    $dataCount = $fields.Length - 4
    $total = ConvertFrom-NmeaInteger $fields[1] -Min 1 -Max 99
    $number = ConvertFrom-NmeaInteger $fields[2] -Min 1 -Max 99
    if ($dataCount -lt 0 -or ($dataCount % 4) -gt 1 -or $null -eq $total -or $null -eq $number -or $number -gt $total) { return }
    $signal = if ($dataCount % 4 -eq 1) { $fields[-1] } else { '' }
    $key = "${talker}:$signal"
    if ($number -eq 1) { $State.Pending[$key] = [pscustomobject]@{ Total = $total; Next = 1; Satellites = [Collections.Generic.List[object]]::new() } }
    $pending = $State.Pending[$key]
    if ($null -eq $pending -or $pending.Total -ne $total -or $pending.Next -ne $number) {
        $State.Pending.Remove($key)
        return
    }
    for ($i = 4; $i + 3 -lt $fields.Length; $i += 4) {
        $id = ConvertFrom-NmeaInteger $fields[$i] -Min 1 -Max 999
        if ($null -eq $id) { continue }
        $pending.Satellites.Add([pscustomobject]@{
                System       = Get-NmeaSatelliteSystem $talker $id
                Id           = $id
                Signal       = $signal
                ElevationDeg = ConvertFrom-NmeaInteger $fields[$i + 1] -Min 0 -Max 90
                AzimuthDeg   = ConvertFrom-NmeaInteger $fields[$i + 2] -Min 0 -Max 359
                SnrDbHz      = ConvertFrom-NmeaInteger $fields[$i + 3] -Min 0 -Max 99
                Used         = $false
            })
    }
    $pending.Next++
    if ($number -eq $total) {
        $State.Views[$key] = [pscustomobject]@{ Received = $Now; Satellites = $pending.Satellites.ToArray() }
        $State.Pending.Remove($key)
    }
}

# Current satellites (one row per satellite and signal) and the number of distinct satellites
# used in the fix. Cycles not refreshed for $MaxAgeSeconds are dropped, so a constellation
# that stops reporting disappears. GPGSA and GNGSA listing the same satellite count once.
function Get-NmeaSatelliteReport($State, [DateTimeOffset]$Now, [int]$MaxAgeSeconds = 10) {
    foreach ($table in $State.Views, $State.Used) {
        foreach ($key in @($table.Keys)) {
            if (($Now - $table[$key].Received).TotalSeconds -gt $MaxAgeSeconds) { $table.Remove($key) }
        }
    }
    $used = [Collections.Generic.HashSet[string]]::new()
    foreach ($entry in $State.Used.Values) { foreach ($key in $entry.Keys) { $null = $used.Add($key) } }
    $satellites = foreach ($view in $State.Views.Values) {
        foreach ($satellite in $view.Satellites) {
            $row = $satellite.PSObject.Copy()
            $row.Used = $used.Contains("$($satellite.System):$($satellite.Id)")
            $row
        }
    }
    $satellites = @($satellites | Sort-Object { $script:NmeaSystems.IndexOf($_.System) }, Id, Signal)
    return [pscustomobject]@{ Satellites = $satellites; UsedCount = $used.Count }
}
