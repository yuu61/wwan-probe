# Composition root shared by the entry point, sampling runspace and integration tests.
# Dot-source at the destination scope. Loading definitions performs no device I/O.
param([ValidateSet('Core', 'All')][string]$Components = 'All')

$monitorSources = @(
    'domain/Signal.ps1'
    'domain/Band.ps1'
    'domain/Downgrade.ps1'
    'domain/Handover.ps1'
    'infrastructure/WinRt.ps1'
    'infrastructure/PerfCounter.ps1'
    'infrastructure/CsvFile.ps1'
    'infrastructure/modem/SignalConversion.ps1'
    'infrastructure/modem/IntelCellMeasurement.ps1'
    'infrastructure/modem/IntelStatus.ps1'
    'infrastructure/modem/QuectelStatus.ps1'
    'infrastructure/modem/FibocomStatus.ps1'
    'infrastructure/modem/AtProfile.ps1'
    'infrastructure/modem/Modem.ps1'
    'infrastructure/modem/ModemObservation.ps1'
    'infrastructure/gnss/Gps.ps1'
    'infrastructure/gnss/GnssDevice.ps1'
    'infrastructure/gnss/Nmea.ps1'
    'infrastructure/gnss/NmeaReceiver.ps1'
    'application/Snapshot.ps1'
    'application/SnapshotLog.ps1'
    'application/MonitorSession.ps1'
    'application/MonitorSampler.ps1'
)
if ($Components -eq 'All') {
    $monitorSources += @(
        'presentation/Gauge.ps1'
        'presentation/Frame.ps1'
        'presentation/ConsoleRenderer.ps1'
        'presentation/PlainMonitor.ps1'
        'presentation/TuiMonitor.ps1'
    )
}
foreach ($monitorSource in $monitorSources) { . (Join-Path $PSScriptRoot $monitorSource) }
