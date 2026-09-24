#Requires -Version 7.4
# Native GNSS experiment, separate from the monitor. -Nmea temporarily enables
# driver logging and restores NONE on exit. It shares the NMEA lock with lte_monitor.ps1 -Nmea
# and fails while another NMEA listener runs.
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
. (Join-Path $root 'src/Load.ps1') -Components Core
Import-WinRtProjection -LibDir (Join-Path $root 'lib')
$devices = @(Get-GnssDeviceInterface)
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
        $probe = Open-GnssDevice $device.Id
        $summary.Opened = $true
        $capability = Get-GnssCapability $probe
        $version = $capability.DriverVersion
        $summary.DriverVersion = $version
        $summary.MultipleFixSessions = $capability.MultipleFixSessions
        $summary.MultipleAppSessions = $capability.MultipleAppSessions
        $summary.ContinuousTracking = $capability.ContinuousTracking
        if ($Nmea) {
            $lock = Enter-GnssNmeaLock
            # Let Windows own the fix session and assistance data. Only the NMEA
            # logging command/listener uses the native handle.
            $receiver = Start-GpsReceiver
            if ($receiver.Error) { throw $receiver.Error }
            $loggingAttempted = $true
            Set-GnssNmeaLogging $probe $version $true
            $types = [Collections.Generic.HashSet[string]]::new()
            $satelliteSentences = @{}
            $pending = ''
            $timer = [Diagnostics.Stopwatch]::StartNew()
            while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
                $remainingMs = [Math]::Max(1, [Math]::Min(3000, ($Seconds * 1000) - $timer.ElapsedMilliseconds))
                $chunk = Read-GnssNmea $probe ([uint32]$remainingMs)
                if ($null -eq $chunk) { $summary.ReceiveTimeouts++ }
                else {
                    $summary.NmeaEvents++
                    # Messages can span event buffers. Only complete, checksum-valid
                    # sentences are accepted; coordinates never enter this report.
                    $split = Split-NmeaStream ($pending + $chunk)
                    $pending = $split.Rest
                    foreach ($sentence in $split.Sentences) {
                        $fields = $sentence.Substring(1, $sentence.LastIndexOf('*') - 1).Split(',')
                        if ($fields[0] -notmatch '^[A-Z]{5}$') { continue }
                        $null = $types.Add($fields[0])
                        if ($fields[0].EndsWith('GSV') -and $fields.Length -ge 4) {
                            # Retain the latest message for each sequence part/signal.
                            $signalId = if (($fields.Length - 4) % 4 -eq 1) { $fields[-1] } else { '' }
                            $satelliteSentences["$($fields[0]):$($fields[2]):$signalId"] = $sentence
                        }
                        elseif ($fields[0].EndsWith('GSA') -and $fields.Length -ge 18) {
                            $systemId = if ($fields.Length -gt 18) { $fields[18] } else { '' }
                            $satelliteSentences["$($fields[0]):$systemId"] = $sentence
                        }
                    }
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
            if ($loggingAttempted) { Set-GnssNmeaLogging $probe $version $false }
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
