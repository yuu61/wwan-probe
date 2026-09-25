# Hardware-free NMEA satellite parsing, helper state, rendering and key checks.
# Sentences are real L860-GL output (2026-09-24); coordinates are never involved.
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
$capture = @(
    '$GPGSV,3,1,12,02,87,163,17,08,60,031,32,01,59,199,,07,46,255,16,1*6B'
    '$GPGSV,3,2,12,30,29,298,,27,28,066,21,16,20,121,,10,16,053,19,1*6E'
    '$GPGSV,3,3,12,14,14,311,,03,02,172,,17,02,265,,23,00,029,,1*6E'
    '$GLGSV,2,1,06,74,66,141,,75,55,331,25,84,47,025,25,73,16,147,,1*70'
    '$GLGSV,2,2,06,86,15,228,,76,03,327,,1*78'
    '$GPGSA,A,3,02,08,07,27,10,,,,,,,,2.93,2.01,2.13*00'
    '$GNGSA,A,3,02,08,07,27,10,,,,,,,,2.93,2.01,2.13,1*03'
    '$GNGSA,A,3,75,84,,,,,,,,,,,2.93,2.01,2.13,2*07'
)

# Driver events cut sentences anywhere; corrupt sentences and noise are dropped.
$stream = ($capture -join "`r`n") + "`r`n" + '$GPGSV,1,1,00,1*00' + "`r`nnoise`r`n" + '$GPGGA,1234'
$sentences = [Collections.Generic.List[string]]::new()
$rest = ''
for ($i = 0; $i -lt $stream.Length; $i += 37) {
    $split = Split-NmeaStream ($rest + $stream.Substring($i, [math]::Min(37, $stream.Length - $i)))
    $sentences.AddRange([string[]]$split.Sentences)
    $rest = $split.Rest
}
Assert-True ($sentences.Count -eq $capture.Count -and $sentences[0] -eq $capture[0] -and $sentences[-1] -eq $capture[-1]) 'Split sentences were lost or a bad checksum was accepted.'
Assert-True ($rest -eq '$GPGGA,1234') 'The incomplete tail was not kept for the next event.'
Assert-True ((Split-NmeaStream ('$' + ('A' * 300))).Rest -eq '') 'An overlong tail was kept.'
Write-Output 'PASS: NMEA stream framing and checksum'

$state = New-NmeaSatelliteState
foreach ($sentence in $capture) { Add-NmeaSentence $state $sentence $now }
$report = Get-NmeaSatelliteReport $state $now
Assert-True ($report.Satellites.Count -eq 18 -and $report.UsedCount -eq 7) 'GPGSA and GNGSA were double counted or satellites were lost.'
$gps2 = $report.Satellites | Where-Object { $_.System -eq 'GPS' -and $_.Id -eq 2 }
Assert-True ($gps2.ElevationDeg -eq 87 -and $gps2.AzimuthDeg -eq 163 -and $gps2.SnrDbHz -eq 17 -and $gps2.Used -and $gps2.Signal -eq '1') 'GSV fields were misread.'
$glonass = @($report.Satellites | Where-Object System -EQ 'GLONASS')
Assert-True ($glonass.Count -eq 6 -and @($glonass | Where-Object Used).Id -join ',' -eq '75,84') 'GLONASS usage did not match GNGSA system 2.'
Assert-True ($null -eq ($glonass | Where-Object Id -EQ 74).SnrDbHz) 'An untracked satellite got an SNR.'
$order = @($report.Satellites | ForEach-Object { "$($_.System):$($_.Id)" })
Assert-True (($order[0..8] -join ',') -eq 'GPS:8,GLONASS:75,GLONASS:84,GPS:27,GPS:10,GPS:2,GPS:7,GLONASS:74,GPS:1' -and
    ($order[-3..-1] -join ',') -eq 'GPS:3,GPS:17,GPS:23') 'Satellites are not sorted by use, SNR, elevation and ID.'
# A used satellite precedes a stronger unused one; equal SNR and elevation fall back to constellation order.
$sortState = New-NmeaSatelliteState
Add-NmeaSentence $sortState '$GPGSV,1,1,03,05,10,100,40,06,20,200,30,07,30,300,,1*00' $now
Add-NmeaSentence $sortState '$GLGSV,1,1,01,70,10,100,40,1*00' $now
Add-NmeaSentence $sortState ('$GPGSA,A,3,06' + (',' * 11) + ',2.0,1.0,1.0,1*00') $now
$sortOrder = @((Get-NmeaSatelliteReport $sortState $now).Satellites | ForEach-Object { "$($_.System):$($_.Id)" }) -join ','
Assert-True ($sortOrder -eq 'GPS:6,GPS:5,GLONASS:70,GPS:7') "Unexpected sort priority: $sortOrder"

# An incomplete or out-of-order cycle never replaces the last complete one.
Add-NmeaSentence $state '$GPGSV,3,1,01,05,10,100,30,1*00' $now
Add-NmeaSentence $state '$GPGSV,3,3,01,06,10,100,30,1*00' $now
Assert-True (@((Get-NmeaSatelliteReport $state $now).Satellites | Where-Object System -EQ 'GPS').Count -eq 12) 'A partial GSV cycle replaced the complete one.'
# Losing the fix clears usage; stale constellations disappear.
Add-NmeaSentence $state '$GNGSA,A,1,,,,,,,,,,,,,,,,1*1D' $now
Add-NmeaSentence $state '$GNGSA,A,1,,,,,,,,,,,,,,,,2*1E' $now
Add-NmeaSentence $state '$GPGSA,A,1,,,,,,,,,,,,,,,*1E' $now
Assert-True ((Get-NmeaSatelliteReport $state $now).UsedCount -eq 0) 'A no-fix GSA kept the used satellites.'
Add-NmeaSentence $state '$GPGSV,1,1,00,1*64' $now.AddSeconds(8)
$later = Get-NmeaSatelliteReport $state $now.AddSeconds(11)
Assert-True ($later.Satellites.Count -eq 0 -and $later.UsedCount -eq 0) 'Expired or empty cycles kept satellites.'
Assert-True ((Get-NmeaSatelliteSystem 'GP' 40) -eq 'SBAS' -and (Get-NmeaSatelliteSystem 'GP' 194) -eq 'QZSS' -and (Get-NmeaSatelliteSystem 'GA' 5) -eq 'Galileo') 'Constellation mapping is wrong.'
Write-Output 'PASS: GSV cycles, GSA usage union, aging and constellations'

# Fix state from GGA / RMC / GSA: real L860-GL field values (2026-09-25) with dummy coordinates.
function New-TestSentence([string]$Body) {
    $checksum = 0
    foreach ($character in $Body.ToCharArray()) { $checksum = $checksum -bxor [int]$character }
    return '${0}*{1:X2}' -f $Body, $checksum
}
$fixState = New-NmeaSatelliteState
foreach ($body in 'GNGGA,205350.033,3500.0000,N,13900.0000,E,1,13,0.82,14.600,M,39.432,M,,',
    'GNRMC,205349.083,A,3500.0000,N,13900.0000,E,26.136,300.9,240926,,,A,V',
    'GNGSA,A,3,65,88,66,81,,,,,,,,,1.36,0.79,1.11,2') {
    Add-NmeaSentence $fixState (New-TestSentence $body) $now
}
$fix = (Get-NmeaSatelliteReport $fixState $now).Fix
$goodFix = $fix
Assert-True ($fix.Dimension -eq '3D' -and $fix.Quality -eq 'GPS' -and $fix.SatellitesUsed -eq 13) 'GSA / GGA fix fields were misread.'
Assert-True ($fix.AltitudeMslM -eq 14.6 -and $fix.GeoidSeparationM -eq 39.432 -and $fix.Valid -and $fix.Mode -eq 'Autonomous') 'GGA altitude or RMC status was misread.'
Assert-True (((Get-NmeaSatelliteReport $fixState $now) | ConvertTo-Json -Depth 5) -notmatch '3500|13900|205350') 'The report leaked GGA / RMC position or time fields.'
# A GP duplicate does not override the combined GN solution; unknown codes stay visible.
Add-NmeaSentence $fixState (New-TestSentence 'GPGGA,205351.033,3500.0000,N,13900.0000,E,2,05,0.82,,M,,M,,') $now
Add-NmeaSentence $fixState (New-TestSentence 'GNRMC,205352.083,V,,,,,,,240926,,,X,V') $now
$fix = (Get-NmeaSatelliteReport $fixState $now).Fix
Assert-True ($fix.Quality -eq 'GPS' -and $fix.SatellitesUsed -eq 13) 'A GP sentence replaced the GN solution.'
Assert-True ($fix.Valid -eq $false -and $fix.Mode -eq 'Unknown (X)') 'An invalid RMC or unknown mode was hidden.'
Add-NmeaSentence $fixState (New-TestSentence 'GNGGA,205353.033,,,,,0,00,,,M,,M,,') $now
$fix = (Get-NmeaSatelliteReport $fixState $now).Fix
Assert-True ($fix.Quality -eq 'Invalid' -and $fix.SatellitesUsed -eq 0 -and $null -eq $fix.AltitudeMslM) 'A no-fix GGA kept the old altitude.'
$fix = (Get-NmeaSatelliteReport $fixState $now.AddSeconds(11)).Fix
Assert-True ($null -eq $fix.Dimension -and $null -eq $fix.Quality -and $null -eq $fix.Valid) 'Expired fix values were kept.'
Write-Output 'PASS: GGA / RMC / GSA fix state, GN preference, aging and no coordinates'

# Helper state file round trip. A replace during a read fails softly and succeeds on retry.
$directory = Join-Path ([IO.Path]::GetTempPath()) "wwan-nmea-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
try {
    $path = Join-Path $directory 'state.json'
    Assert-True ($null -eq (Read-NmeaState $path)) 'A missing state file was not treated as not yet published.'
    $published = [ordered]@{
        Status = 'Receiving'; Error = $null; UpdatedUnixMs = $now.ToUnixTimeMilliseconds(); NmeaUnixMs = $now.ToUnixTimeMilliseconds()
        Satellites = $report.Satellites; UsedCount = $report.UsedCount; Fix = $goodFix
    }
    Assert-True (Write-NmeaState $path $published) 'State was not written.'
    $held = [IO.File]::Open($path, 'Open', 'Read', [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
    try { Assert-True (-not (Write-NmeaState $path $published)) 'A replace during a read did not report a retry.' }
    finally { $held.Dispose() }
    Assert-True (Write-NmeaState $path $published) 'The retry after the read failed.'
    $observation = ConvertFrom-NmeaState (Read-NmeaState $path) -Now $now.AddSeconds(2)
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
Assert-True ($observation.Status -eq 'Receiving' -and $observation.InView -eq 18 -and $observation.Used -eq 7) 'State round trip lost counts.'
Assert-True (($observation.Systems.Keys -join ',') -eq 'GPS,GLONASS' -and $observation.Systems.GPS.InView -eq 12 -and $observation.Systems.GLONASS.Used -eq 2) 'Per-constellation counts are wrong.'
Assert-True ($observation.Fix.Dimension -eq '3D' -and $observation.Fix.AltitudeMslM -eq 14.6 -and $observation.Fix.Valid) 'The fix state did not survive the state file.'

$receiving = [pscustomobject]@{ Status = 'Receiving'; UpdatedUnixMs = $now.ToUnixTimeMilliseconds(); NmeaUnixMs = $null; Satellites = @(); UsedCount = 0 }
Assert-True ((ConvertFrom-NmeaState $null -Now $now).Status -eq 'Starting') 'A helper without a report was not Starting.'
Assert-True ((ConvertFrom-NmeaState $receiving -Now $now.AddSeconds(11)).Status -eq 'Stale') 'A stopped heartbeat was not Stale.'
Assert-True (-not (ConvertFrom-NmeaState $receiving -Now $now).NmeaReceived) 'NMEA was reported before any sentence.'
$failed = ConvertFrom-NmeaState ([pscustomobject]@{ Status = 'Error'; Error = 'No GNSS device interface found.' }) -HelperExited $true -Now $now
Assert-True ($failed.Status -eq 'Unavailable' -and $failed.Error -eq 'No GNSS device interface found.') 'The helper error was not shown.'
$crashed = ConvertFrom-NmeaState $receiving -HelperExited $true -ExitCode 1 -Now $now
Assert-True ($crashed.Status -eq 'Unavailable' -and $crashed.Error -match 'code 1') 'A crashed helper looked alive.'
$declined = Get-NmeaObservation ([pscustomobject]@{ Process = $null; StateDir = $null; Error = 'NMEA helper not started: The operation was canceled by the user.' })
Assert-True ($declined.Status -eq 'Unavailable' -and $declined.Error -match 'canceled') 'A declined UAC prompt was not shown.'
Assert-True ($null -eq (Get-NmeaObservation $null)) 'NMEA was queried without opt-in.'
$fixture = { function Get-ModemObservation { [pscustomobject]@{ Timestamp = 'test'; Serving = @(); Error = $null } } }
. $fixture
$snapshot = Get-LteSnapshot $null $null $null ([pscustomobject]@{ Error = 'declined' })
Assert-True ($null -eq $snapshot.Error -and $snapshot.Satellites.Status -eq 'Unavailable') 'An NMEA failure invalidated LTE.'
# A helper handle that cannot be queried (unstarted Process: WaitForExit throws) or a broken
# receiver must neither fail the LTE sample nor the monitor's shutdown.
$snapshot = Get-LteSnapshot $null $null $null ([pscustomobject]@{ Process = [Diagnostics.Process]::new(); StateDir = $null; Error = $null })
Assert-True ($null -eq $snapshot.Error -and $snapshot.Satellites.Status -eq 'Unavailable') 'A broken receiver failed the LTE sample.'
$directory = Join-Path ([IO.Path]::GetTempPath()) "wwan-nmea-test-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
try {
    Stop-NmeaReceiver ([pscustomobject]@{ Process = [Diagnostics.Process]::new(); StateDir = $directory; Error = $null }) -TimeoutMs 10
    Assert-True (Test-Path -LiteralPath (Join-Path $directory 'stop')) 'The stop request was not left for the helper.'
}
finally { Remove-Item -LiteralPath $directory -Recurse -Force }
$snapshot = Get-LteSnapshot $null $null $null ([pscustomobject]@{ Error = 'declined' })
Write-Output 'PASS: helper state file, observation states and failure isolation'

# Main screen summary, the [s] view and its footer.
$session = [pscustomobject]@{
    Config = [pscustomobject]@{ Count = 0; Interval = 0; CsvPath = '' }
    Summary = [pscustomobject]@{ Model = 'Test' }; Snapshot = $snapshot; Iteration = 1
    History = New-SignalHistory; HandoverLog = New-HandoverLog; NmeaReceiver = [pscustomobject]@{}
}
$snapshot.Satellites = $observation
$view = @{ Unicode = $false; LastHeight = 30 }
$frame = Get-MonitorFrame $session $view 100
$text = $frame.Body.Text -join "`n"
Assert-True ($text -match 'Satellites: 18 in view \(GPS 12, GLONASS 6\), 7 used  \[s\]' -and $frame.Footer.Text -match '\[s\] Satellites') 'The satellite summary or key is missing.'
Assert-True ($text -match 'Fix \(NMEA\): 3D   Quality: GPS   Mode: Autonomous \(valid\)   Sats used: 13' -and
    $text -match 'Altitude MSL: 14[.,]6 m   Geoid separation: 39[.,]4 m') 'The NMEA fix lines are missing.'
$view.SatelliteVisible = $true
$frame = Get-MonitorFrame $session $view 100
$rows = @($frame.Body | Where-Object { $_.Text -match '^ (GPS|GLONASS) ' })
Assert-True ($rows.Count -eq 18 -and $frame.Footer.Text -match '\[s\] Monitor') 'The satellite list is incomplete.'
Assert-True (@($rows | Where-Object Color -EQ 'Green').Count -eq 12 -and @($rows | Where-Object Color -EQ 'Magenta').Count -eq 6) 'Constellations are not colored.'
Assert-True ($rows[0].Text -match '^ GPS +8 +1 +60 +31 +32 +yes ' -and ($rows | Where-Object Text -Match '^ GPS +1 ').Text -match '^ GPS +1 +1 +59 +199 +n/a +\[ +not tracked +\]' -and
    ($rows | Where-Object Text -Match '^ GPS +2 ').Text -match ' yes ') 'A satellite row is misformatted or not sorted by SNR.'
$view.LastHeight = 12
$view.SatelliteOffset = 99
$frame = Get-MonitorFrame $session $view 100
Assert-True ($view.SatelliteOffset -eq 16 -and $frame.Body.Count -le 12 -and ($frame.Body.Text -join "`n") -match 'Rows 17-18 / 18') 'Satellite scrolling does not fit the screen.'
$session.NmeaReceiver = $null
$snapshot.Satellites = $null
$text = (Get-MonitorFrame $session $view 100).Body.Text -join "`n"
Assert-True ($text -match 'start lte_monitor.ps1 with -Nmea') 'The [s] view did not explain how to enable it.'
$view.SatelliteVisible = $false
$frame = Get-MonitorFrame $session $view 100
Assert-True (($frame.Body.Text -join "`n") -notmatch 'Satellites:' -and $frame.Footer.Text -notmatch '\[s\]') 'Satellites were shown without -Nmea.'
Write-Output 'PASS: satellite summary, colored list, scrolling and opt-in'

$script:keys = [Collections.Generic.Queue[ConsoleKeyInfo]]::new()
function Read-TuiKey { if ($script:keys.Count -gt 0) { return $script:keys.Dequeue() } }
function Send-TestKey([ConsoleKey[]]$Key) {
    foreach ($k in $Key) { $script:keys.Enqueue([ConsoleKeyInfo]::new([char]0, $k, $false, $false, $false)) }
}
$view = @{ HandoverVisible = $true; HandoverOffset = 2; SatelliteVisible = $false; SatelliteOffset = 0; ChartRows = 2; ChartVisible = New-ChartVisibility }
Send-TestKey S, DownArrow, DownArrow, UpArrow
Read-TuiInput $view
Assert-True ($view.SatelliteVisible -and -not $view.HandoverVisible -and $view.SatelliteOffset -eq 1 -and $view.ChartRows -eq 2) 's did not open a scrollable list.'
Send-TestKey H
Read-TuiInput $view
Assert-True ($view.HandoverVisible -and -not $view.SatelliteVisible) 'h and s views overlapped.'
Send-TestKey S, S
Read-TuiInput $view
Assert-True (-not $view.SatelliteVisible -and -not $view.HandoverVisible -and $view.SatelliteOffset -eq 0) 's did not return to the monitor.'
Write-Output 'PASS: s toggles the satellite list, exclusive with h'

# A misspelled option must fail instead of silently running without NMEA (binding fails
# before the script touches the modem). -Nema is accepted as a spelling of -Nmea.
$entry = Join-Path $root 'lte_monitor.ps1'
$output = pwsh -NoProfile -File $entry -Nmae 2>&1 | Out-String
Assert-True ($LASTEXITCODE -ne 0 -and $output -match 'Nmae') 'An unknown option was ignored.'
Assert-True ((Get-Command $entry).Parameters.Nmea.Aliases -contains 'Nema') '-Nema is not accepted.'
Write-Output 'PASS: unknown options are rejected; -Nema selects -Nmea'
