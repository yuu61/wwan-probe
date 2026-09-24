#Requires -Version 7.4
# Elevated NMEA helper started by Start-NmeaReceiver (NmeaReceiver.ps1); not for direct use.
# Keeps a Windows location session (Geolocator) so the GNSS engine runs, enables the driver's
# NMEA logging on the first GNSS device and publishes GSV/GSA satellites to
# <StateDir>\state.json about once a second. Stops when <StateDir>\stop appears or the monitor
# process ends, then restores NMEA logging to disabled and removes <StateDir>.
# On a failure it keeps the state file with Status = 'Error' for the monitor to show.
param(
    [Parameter(Mandatory)][string]$StateDir,
    [Parameter(Mandatory)][int]$ParentId,
    [Parameter(Mandatory)][long]$ParentStartTicks
)

$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $sourceRoot 'Load.ps1') -Components Core

$statePath = Join-Path $StateDir 'state.json'
$stopPath = Join-Path $StateDir 'stop'
$state = [ordered]@{ Status = 'Starting'; Error = $null; UpdatedUnixMs = 0; NmeaUnixMs = $null; Satellites = @(); UsedCount = 0 }
$parent = $null
$lock = $null
$device = $null
$gps = $null
$loggingEnabled = $false
$version = 0
$finished = $false
try {
    $state.UpdatedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $null = Write-NmeaState $statePath $state
    # Holding the process object also guards against the parent ID being reused.
    $parent = [Diagnostics.Process]::GetProcessById($ParentId)
    if ($parent.StartTime.ToUniversalTime().Ticks -ne $ParentStartTicks) { throw 'The monitor process has already exited.' }
    Import-WinRtProjection -LibDir (Join-Path (Split-Path $sourceRoot -Parent) 'lib')
    $lock = Enter-GnssNmeaLock
    $interfaces = @(Get-GnssDeviceInterface)
    if ($interfaces.Count -eq 0) { throw 'No GNSS device interface found.' }
    $device = Open-GnssDevice $interfaces[0].Id
    $version = (Get-GnssCapability $device).DriverVersion
    # Windows owns the fix session and assistance data; the native handle only listens.
    $gps = Start-GpsReceiver
    if ($gps.Error) { throw $gps.Error }
    $loggingEnabled = $true
    Set-GnssNmeaLogging $device $version $true
    $state.Status = 'Receiving'
    $satellites = New-NmeaSatelliteState
    $buffer = ''
    $published = [Diagnostics.Stopwatch]::StartNew()
    $dirty = $true
    while (-not $finished) {
        # A short listen timeout keeps stop requests and a closed monitor noticed within ~1 s.
        $chunk = Read-GnssNmea $device 1000
        $now = [DateTimeOffset]::UtcNow
        if ($null -ne $chunk) {
            $split = Split-NmeaStream ($buffer + $chunk)
            $buffer = $split.Rest
            foreach ($sentence in $split.Sentences) { Add-NmeaSentence $satellites $sentence $now }
            if ($split.Sentences.Count -gt 0) { $state.NmeaUnixMs = $now.ToUnixTimeMilliseconds() }
        }
        if ($dirty -or $published.ElapsedMilliseconds -ge 1000) {
            $report = Get-NmeaSatelliteReport $satellites $now
            $state.Satellites = $report.Satellites
            $state.UsedCount = $report.UsedCount
            $state.UpdatedUnixMs = $now.ToUnixTimeMilliseconds()
            # A monitor reading the file at this moment only delays the update.
            $dirty = -not (Write-NmeaState $statePath $state)
            $published.Restart()
        }
        $finished = (Test-Path -LiteralPath $stopPath) -or $parent.HasExited
    }
}
catch {
    $state.Status = 'Error'
    $state.Error = $_.Exception.Message
}
finally {
    try {
        if ($loggingEnabled) { Set-GnssNmeaLogging $device $version $false }
    }
    catch {
        $state.Status = 'Error'
        $state.Error = (@($state.Error, "NMEA logging not restored: $($_.Exception.Message)") | Where-Object { $_ }) -join '; '
    }
    finally {
        if ($null -ne $device) { $device.Dispose() }
        Stop-GpsReceiver $gps
        if ($null -ne $lock) { $lock.Dispose() }
        if ($null -ne $parent) { $parent.Dispose() }
        if ($finished -and $state.Status -ne 'Error') { Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction SilentlyContinue }
        else {
            $state.UpdatedUnixMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            $null = Write-NmeaState $statePath $state
        }
    }
}
