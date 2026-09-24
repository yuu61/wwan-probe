#Requires -Version 7.4
# Native GNSS experiment, separate from the monitor. -Nmea temporarily enables
# driver logging and restores NONE on exit. It takes the same named mutex as
# lte_monitor.ps1 -Nmea, so it fails instead of stopping another NMEA listener.
param(
    [switch]$Elevate,
    [switch]$Nmea,
    [ValidateRange(1, 120)][int]$Seconds = 30
)

$ErrorActionPreference = 'Stop'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$isAdmin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    if (-not $Elevate) { throw 'Native GNSS access requires an administrator. Retry with -Elevate to request UAC.' }
    $reportPath = Join-Path ([IO.Path]::GetTempPath()) ("wwan-gnss-$([guid]::NewGuid().ToString('N')).json")
    # Quote PowerShell literals, then encode the whole command to preserve paths
    # containing spaces/apostrophes. No profile or user-provided command is loaded.
    $scriptLiteral = "'" + $PSCommandPath.Replace("'", "''") + "'"
    $reportLiteral = "'" + $reportPath.Replace("'", "''") + "'"
    $nmeaArgument = if ($Nmea) { '-Nmea' } else { '' }
    $childCommand = @"
try {
    `$result = & $scriptLiteral $nmeaArgument -Seconds $Seconds
    `$report = @{ Success = `$true; Result = `$result }
} catch { `$report = @{ Success = `$false; Error = `$_.Exception.Message } }
[IO.File]::WriteAllText($reportLiteral, (`$report | ConvertTo-Json -Depth 10))
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childCommand))
    try {
        $process = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -Verb RunAs -WindowStyle Hidden `
            -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -Wait
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $reportPath)) {
            throw 'The elevated GNSS diagnostic did not return a report.'
        }
        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        if (-not $report.Success) { throw $report.Error }
        return $report.Result
    }
    finally {
        if (Test-Path -LiteralPath $reportPath) { Remove-Item -LiteralPath $reportPath }
    }
}

$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/Load.ps1')
Import-WinRtProjection -LibDir (Join-Path $root 'lib')
if (-not ('WwanProbe.Diagnostics.GnssProbe' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'GnssProbe.cs')
}
$devices = @(Wait-WinRtAsync ([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync(
            'System.Devices.InterfaceClassGuid:="{3336e5e4-018a-4669-84c5-bd05f3bd368b}"')))
if ($devices.Count -eq 0) { throw 'No GNSS device interface found.' }

foreach ($device in $devices) {
    $probe = $null
    $receiver = $null
    $lock = $null
    $loggingAttempted = $false
    $version = 0
    $summary = [ordered]@{
        Elevated = $isAdmin; Device = $device.Name; Opened = $false
        DriverVersion = $null; ContinuousTracking = $null
        MultipleFixSessions = $null; MultipleAppSessions = $null
        NmeaRequested = [bool]$Nmea; NmeaEvents = 0; ReceiveTimeouts = 0
        SentenceTypes = @(); LatestSatelliteSentences = @()
        GpsStatus = $null; GpsSource = $null; SatelliteFixObserved = $false
        LoggingDisableError = $null; Error = $null
    }
    try {
        $probe = [WwanProbe.Diagnostics.GnssProbe]::new($device.Id)
        $summary.Opened = $true
        $capability = $probe.Query(0x220008, $null, 604, 3000)
        if ($capability.Error -ne 0) { throw "GET_DEVICE_CAPABILITY: Win32=$($capability.Error), timeout=$($capability.TimedOut)" }
        if ($capability.Data.Length -lt 36) { throw 'Truncated GNSS capability response.' }
        $version = [BitConverter]::ToUInt32($capability.Data, 4)
        $summary.DriverVersion = $version
        $summary.MultipleFixSessions = [BitConverter]::ToUInt32($capability.Data, 8) -ne 0
        $summary.MultipleAppSessions = [BitConverter]::ToUInt32($capability.Data, 12) -ne 0
        $summary.ContinuousTracking = [BitConverter]::ToUInt32($capability.Data, 32) -ne 0
        if ($Nmea) {
            # Each NMEA listener disables logging on exit; never run next to lte_monitor.ps1 -Nmea.
            $createdNew = $false
            $lock = [Threading.Mutex]::new($true, 'Global\WwanProbeGnssNmea', [ref]$createdNew)
            if (-not $createdNew) { throw 'Another process (e.g. lte_monitor.ps1 -Nmea) is listening to NMEA.' }
            # Let Windows own the fix session and assistance data. Only the NMEA
            # logging command/listener uses the native handle.
            $receiver = Start-GpsReceiver
            if ($receiver.Error) { throw $receiver.Error }
            $loggingAttempted = $true
            $enable = $probe.SetNmeaLogging($version, $true)
            if ($enable.Error -ne 0) { throw "SetNMEALogging: Win32=$($enable.Error), timeout=$($enable.TimedOut)" }
            $types = [Collections.Generic.HashSet[string]]::new()
            $satelliteSentences = @{}
            $pending = ''
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
                $remainingMs = [Math]::Max(1, [Math]::Min(3000, ($Seconds * 1000) - $timer.ElapsedMilliseconds))
                $nmeaEvent = $probe.Query(0x22011C, $null, 8192, [uint32]$remainingMs)
                if ($nmeaEvent.TimedOut) { $summary.ReceiveTimeouts++ }
                elseif ($nmeaEvent.Error -ne 0) { throw "LISTEN_NMEA: Win32=$($nmeaEvent.Error)" }
                else {
                    # GNSS_EVENT union at 528; GNSS_NMEA_DATA header is 8 bytes.
                    if ($nmeaEvent.Data.Length -lt 800 -or [BitConverter]::ToUInt32($nmeaEvent.Data, 8) -ne 13 -or
                        [BitConverter]::ToUInt32($nmeaEvent.Data, 12) -lt 264) { throw 'Invalid GNSS NMEA event.' }
                    $summary.NmeaEvents++
                    $chunk = [Text.Encoding]::ASCII.GetString($nmeaEvent.Data, 536, 256).Split([char]0)[0]
                    $pending += $chunk
                    # Messages can span event buffers. Only accept complete,
                    # checksum-valid sentences; never emit coordinates in this report.
                    while ($pending -match '(?s)\$(?<body>[^$*\r\n]+)\*(?<checksum>[0-9A-Fa-f]{2})') {
                        $match = $Matches
                        $end = $pending.IndexOf($match[0], [StringComparison]::Ordinal) + $match[0].Length
                        $pending = $pending.Substring($end)
                        $checksum = 0
                        foreach ($character in $match.body.ToCharArray()) { $checksum = $checksum -bxor [int]$character }
                        if ($checksum -ne [Convert]::ToInt32($match.checksum, 16)) { continue }
                        $fields = $match.body.Split(',')
                        if ($fields[0] -notmatch '^[A-Z]{5}$') { continue }
                        $null = $types.Add($fields[0])
                        if ($fields[0].EndsWith('GSV') -and $fields.Length -ge 4) {
                            # Retain the latest message for each sequence part/signal.
                            $signalId = if (($fields.Length - 4) % 4 -eq 1) { $fields[-1] } else { '' }
                            $satelliteSentences["$($fields[0]):$($fields[2]):$signalId"] = $match[0]
                        }
                        elseif ($fields[0].EndsWith('GSA') -and $fields.Length -ge 18) {
                            $systemId = if ($fields.Length -gt 18) { $fields[18] } else { '' }
                            $satelliteSentences["$($fields[0]):$systemId"] = $match[0]
                        }
                    }
                    if ($pending.Length -gt 2048) { $pending = '' }
                }
                $gps = Get-GpsObservation $receiver
                $summary.GpsStatus = $gps.Status
                $summary.GpsSource = $gps.Source
                if ($gps.Status -eq 'Fix') { $summary.SatelliteFixObserved = $true }
            }
            $summary.SentenceTypes = @($types | Sort-Object)
            $summary.LatestSatelliteSentences = @($satelliteSentences.Values | Sort-Object)
        }
    }
    catch { $summary.Error = $_.Exception.Message }
    finally {
        try {
            if ($loggingAttempted) {
                $disable = $probe.SetNmeaLogging($version, $false)
                if ($disable.Error -ne 0) { $summary.LoggingDisableError = "Win32=$($disable.Error), timeout=$($disable.TimedOut)" }
            }
        }
        catch { $summary.LoggingDisableError = $_.Exception.Message }
        finally {
            if ($null -ne $probe) { $probe.Dispose() }
            Stop-GpsReceiver $receiver
            if ($null -ne $lock) { $lock.Dispose() }
        }
    }
    [pscustomobject]$summary
}
