# Infrastructure: NMEA 0183 satellites (GSV = satellites in view, GSA = used in the fix) and
# the receiver's fix state (GSA, GGA, RMC). Pure parsing, also used by hardware-free tests.
# GGA and RMC also carry the position: only the fields listed under Fix are read, so reports
# never contain coordinates.
#
# Satellite: @{ System; Id; Signal; ElevationDeg; AzimuthDeg; SnrDbHz; Used }
#   Id is the NMEA ID as reported (GLONASS 65-96 in GP/GN and GL sentences alike);
#   Signal is the NMEA 4.10 signal ID ('' before 4.10); missing values are $null.
#
# Fix: @{ Dimension (GSA: NoFix | 2D | 3D); Quality (GGA fix quality); SatellitesUsed (GGA);
#         AltitudeMslM / GeoidSeparationM (GGA, metres); Valid (RMC status A); Mode (RMC mode) }
#   Each value is $null when its sentence has not been received recently.

# GSA system ID (NMEA 4.10) -> talker of that constellation.
$script:NmeaSystemTalkers = @{ '1' = 'GP'; '2' = 'GL'; '3' = 'GA'; '4' = 'GB'; '5' = 'GQ'; '6' = 'GI' }
$script:NmeaTalkerSystems = @{ GL = 'GLONASS'; GA = 'Galileo'; GB = 'BeiDou'; BD = 'BeiDou'; GQ = 'QZSS'; QZ = 'QZSS'; GI = 'NavIC' }
# Display order of the constellations.
$script:NmeaSystems = @('GPS', 'QZSS', 'SBAS', 'GLONASS', 'Galileo', 'BeiDou', 'NavIC', 'Unknown')
# Sentences older than this are dropped from reports.
$script:NmeaMaxAgeSeconds = 10
# GGA fix quality and GSA fix type codes.
$script:NmeaFixQualities = @{
    '0' = 'Invalid'; '1' = 'GPS'; '2' = 'DGPS'; '3' = 'PPS'; '4' = 'RTK fixed'
    '5' = 'RTK float'; '6' = 'Estimated'; '7' = 'Manual'; '8' = 'Simulation'
}
$script:NmeaFixDimensions = @{ '1' = 'NoFix'; '2' = '2D'; '3' = '3D' }
# RMC mode indicator (NMEA 2.3+; F / P / R from 4.0).
$script:NmeaFixModes = @{
    A = 'Autonomous'; D = 'Differential'; E = 'Estimated'; F = 'RTK float'; M = 'Manual'
    N = 'Not valid'; P = 'Precise'; R = 'RTK fixed'; S = 'Simulator'
}

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

function ConvertFrom-NmeaDecimal([string]$Text) {
    $value = 0.0
    if (-not [double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $null }
    if (-not [double]::IsFinite($value)) { return $null }
    return $value
}

# Label for an NMEA code; an unlisted code is kept visible instead of being dropped.
function Get-NmeaCodeLabel([hashtable]$Labels, [string]$Code) {
    if (-not $Code) { return $null }
    if ($Labels.ContainsKey($Code)) { return $Labels[$Code] }
    return "Unknown ($Code)"
}

# Stores the fix values of one sentence type. GN sentences describe the combined
# multi-constellation solution, so a GP duplicate does not replace a recent GN one.
function Set-NmeaFixSource {
    # In-memory parser state only; ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($State, [string]$Source, [string]$Talker, [DateTimeOffset]$Now, [hashtable]$Values)

    $previous = $State.Fix[$Source]
    if ($previous -and $previous.Talker -eq 'GN' -and $Talker -ne 'GN' -and
        ($Now - $previous.Received).TotalSeconds -le $script:NmeaMaxAgeSeconds) { return }
    $Values.Received = $Now
    $Values.Talker = $Talker
    $State.Fix[$Source] = [pscustomobject]$Values
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

    # Views / Pending: GSV cycles per talker and signal; Used: GSA per talker and system ID;
    # Fix: latest GSA / GGA / RMC fix values.
    return [pscustomobject]@{ Views = @{}; Pending = @{}; Used = @{}; Fix = @{} }
}

# Applies one checksum-valid sentence received at $Now. A GSV cycle (message 1..N) replaces
# the previous one only when complete and in order. GGA and RMC contribute only the fix
# fields (never the position); other sentence types are ignored.
function Add-NmeaSentence($State, [string]$Sentence, [DateTimeOffset]$Now) {
    $fields = $Sentence.Substring(1, $Sentence.LastIndexOf('*') - 1).Split(',')
    if ($fields[0] -notmatch '^(?<talker>[A-Z]{2})(?<type>GSV|GSA|GGA|RMC)$') { return }
    $talker = $Matches.talker
    if ($Matches.type -eq 'GGA') {
        # 6 quality, 7 satellites used, 9-10 altitude above mean sea level, 11-12 geoid separation.
        if ($fields.Length -lt 13) { return }
        Set-NmeaFixSource -State $State -Source 'GGA' -Talker $talker -Now $Now -Values @{
            Quality          = Get-NmeaCodeLabel $script:NmeaFixQualities $fields[6]
            SatellitesUsed   = ConvertFrom-NmeaInteger $fields[7] -Min 0 -Max 99
            AltitudeMslM     = if ($fields[10] -eq 'M') { ConvertFrom-NmeaDecimal $fields[9] }
            GeoidSeparationM = if ($fields[12] -eq 'M') { ConvertFrom-NmeaDecimal $fields[11] }
        }
        return
    }
    if ($Matches.type -eq 'RMC') {
        # 2 status (A = valid, V = warning), 12 mode indicator (NMEA 2.3+).
        if ($fields.Length -lt 3) { return }
        Set-NmeaFixSource -State $State -Source 'RMC' -Talker $talker -Now $Now -Values @{
            Valid = if ($fields[2] -eq 'A') { $true } elseif ($fields[2] -eq 'V') { $false } else { $null }
            Mode  = if ($fields.Length -gt 12) { Get-NmeaCodeLabel $script:NmeaFixModes $fields[12] }
        }
        return
    }
    if ($Matches.type -eq 'GSA') {
        if ($fields.Length -lt 18) { return }
        Set-NmeaFixSource -State $State -Source 'GSA' -Talker $talker -Now $Now -Values @{ Dimension = Get-NmeaCodeLabel $script:NmeaFixDimensions $fields[2] }
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
# Fix values age out the same way (see Fix in the header).
function Get-NmeaSatelliteReport($State, [DateTimeOffset]$Now, [int]$MaxAgeSeconds = $script:NmeaMaxAgeSeconds) {
    foreach ($table in $State.Views, $State.Used, $State.Fix) {
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
    # Used in the fix first, then strongest, then highest; a missing SNR or elevation sorts last.
    # Remaining ties: constellation order, ID, signal.
    $satellites = @($satellites | Sort-Object @{ Expression = 'Used'; Descending = $true },
        @{ Expression = { if ($null -eq $_.SnrDbHz) { -1 } else { $_.SnrDbHz } }; Descending = $true },
        @{ Expression = { if ($null -eq $_.ElevationDeg) { -1 } else { $_.ElevationDeg } }; Descending = $true },
        @{ Expression = { $script:NmeaSystems.IndexOf($_.System) } }, Id, Signal)
    $gga = $State.Fix['GGA']
    $rmc = $State.Fix['RMC']
    $fix = [pscustomobject]@{
        Dimension        = $State.Fix['GSA'].Dimension
        Quality          = $gga.Quality
        SatellitesUsed   = $gga.SatellitesUsed
        AltitudeMslM     = $gga.AltitudeMslM
        GeoidSeparationM = $gga.GeoidSeparationM
        Valid            = $rmc.Valid
        Mode             = $rmc.Mode
    }
    return [pscustomobject]@{ Satellites = $satellites; UsedCount = $used.Count; Fix = $fix }
}
