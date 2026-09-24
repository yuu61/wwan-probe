# Hardware-free regression checks for the shared measurement and adapter contracts.
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

# Counter failures, invalid samples and actual zero must remain distinguishable.
function Get-Counter {
    if ($script:counterFailure) { throw 'counter unavailable' }
    return @{ CounterSamples = $script:counterSamples }
}
$script:counterFailure = $true
$traffic = Get-AdapterTraffic
Assert-True ($null -eq $traffic.RxKB -and $null -eq $traffic.TxKB -and $null -eq $traffic.BwMbps -and $traffic.Error) 'Failed counters became zero.'
$script:counterFailure = $false
$script:counterSamples = @(
    [pscustomobject]@{ Path = '\Network Interface(test)\Current Bandwidth'; CookedValue = 1000000; Status = 0 }
    [pscustomobject]@{ Path = '\Network Interface(test)\Bytes Received/sec'; CookedValue = 0; Status = 0 }
    [pscustomobject]@{ Path = '\Network Interface(test)\Bytes Sent/sec'; CookedValue = 0; Status = 1 }
)
$traffic = Get-AdapterTraffic
Assert-True ($traffic.RxKB -eq 0 -and $traffic.TxKB -eq 0 -and $traffic.BwMbps -eq 1 -and -not $traffic.Error) 'Valid zero was treated as missing.'
$script:counterSamples[2].Status = 0xC0000BC6
$traffic = Get-AdapterTraffic
Assert-True ($traffic.RxKB -eq 0 -and $null -eq $traffic.TxKB -and $traffic.Error) 'Invalid counter status was accepted.'
$script:counterSamples = @()
$traffic = Get-AdapterTraffic
Assert-True ($null -eq $traffic.RxKB -and $traffic.Error) 'An empty counter response became zero.'
Write-Output 'PASS: unavailable, invalid, empty and zero traffic readings'

# The same normalized snapshot must be built on the main thread and in the real runspace.
# Stub only device reads; use the production adapter, snapshot, history, CSV and frame code.
$installFixture = {
    $script:fixtureCells = @{
        ServingCellsLte = @(
            [pscustomobject]@{
                CellId = 100; ProviderId = ''; ReferenceSignalReceivedPowerInDBm = 255
                ReferenceSignalReceivedQualityInDBm = -11; ChannelNumber = 100
                PhysicalCellId = 10; TrackingAreaCode = 20; TimingAdvanceInBitPeriods = 3
            }
            [pscustomobject]@{
                CellId = 200; ProviderId = '44010'; ReferenceSignalReceivedPowerInDBm = -90
                ReferenceSignalReceivedQualityInDBm = -10; ChannelNumber = 1300
                PhysicalCellId = 11; TrackingAreaCode = 20; TimingAdvanceInBitPeriods = 4
            }
            [pscustomobject]@{
                CellId = 300; ProviderId = '44010'; ReferenceSignalReceivedPowerInDBm = 255
                ReferenceSignalReceivedQualityInDBm = 255; ChannelNumber = 6300
            }
        )
    }
    function Get-ModemCellsInfo { return $script:fixtureCells }
    function Get-Counter { throw 'counter unavailable' }
    function Get-AtStatus { return @{ Cells = @(); Neighbors = @(); TempC = 40; Rssnr = 10; Ca = $null } }
}
. $installFixture
$modem = @{ CurrentNetwork = @{ RegisteredProviderId = '44010'; RegisteredDataClass = 'Lte' } }
$snapshot = Get-LteSnapshot $modem
Assert-True (-not $snapshot.Error -and $snapshot.TrafficError -match 'counter unavailable') 'A traffic failure invalidated the whole observation.'
Assert-True ($snapshot.PrimaryCell.CellId -eq 100 -and $snapshot.Serving.Count -eq 3 -and $snapshot.SecondaryCells.Count -eq 2) 'Cell roles were changed by missing RSRP.'
Assert-True ($snapshot.PrimaryCell.Provider -eq '44010' -and $snapshot.PrimaryCell.Ta -eq 3 -and $snapshot.PrimaryCell.RsrqDb -eq -11) 'Primary metadata was lost.'
Assert-True ($null -eq $snapshot.PrimaryCell.RsrpDbm -and $null -eq $snapshot.PrimaryCell.Quality) 'Missing RSRP became a classified signal.'

$sampler = New-MonitorSampler
try {
    $null = $sampler.Pipeline.AddScript($installFixture.ToString()).Invoke()
    Start-MonitorSample $sampler $modem
    while (-not $sampler.Pending.IsCompleted) { Start-Sleep -Milliseconds 25 }
    $background = Receive-MonitorSample $sampler
    $foregroundData = $snapshot | Select-Object * -ExcludeProperty Timestamp | ConvertTo-Json -Depth 8 -Compress
    $backgroundData = $background | Select-Object * -ExcludeProperty Timestamp | ConvertTo-Json -Depth 8 -Compress
    Assert-True ($foregroundData -ceq $backgroundData) 'Foreground and background measurement contracts differ.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: shared loader and foreground/background snapshot equivalence'

$session = [pscustomobject]@{
    Config = [pscustomobject]@{ Count = 0; Interval = 0; CsvPath = '' }
    Summary = [pscustomobject]@{ Model = 'Test'; RatConfig = $null }
    History = New-SignalHistory; HistoryMax = 600
    HandoverLog = New-HandoverLog; DowngradeLog = New-DowngradeLog
    Snapshot = $null; Iteration = 0
}
Add-MonitorSnapshot $session $snapshot
Assert-True ([double]::IsNaN($session.History.Rsrp[0]) -and $session.History.Rsrq[0] -eq -11) 'History promoted an SCell or discarded the primary RSRQ.'
Assert-True ([double]::IsNaN($session.History.RxKB[0]) -and $session.History.TempC[0] -eq 40) 'History did not preserve missing traffic and valid temperature.'
Assert-True ($session.HandoverLog.Previous.CellId -eq 100) 'Handover and history used different primary cells.'
$row = ConvertTo-SnapshotLogRow $snapshot
Assert-True ($row.CellID -eq 100 -and $null -eq $row.RSRP_dBm -and $row.SCell_EARFCN -eq '1300+6300' -and $row.SCell_RSRP_dBm -eq '-90+') 'CSV promoted or lost a carrier, or misaligned missing SCell fields.'
$view = @{ Unicode = $false; ChartVisible = New-ChartVisibility; ChartRows = 2 }
$text = (Get-MonitorFrame $session $view 120).Body.Text -join "`n"
Assert-True ($text -match 'RSRP: n/a  RSRQ: -11 dB' -and $text -match 'CellID:100') 'An unmeasured primary is missing from the frame.'
Assert-True ($text -match 'BW: n/a   RX: n/a   TX: n/a' -and $text -match 'Traffic: counter unavailable') 'The frame presents missing traffic as zero.'

$csvPath = [IO.Path]::GetTempFileName()
try {
    Initialize-SnapshotLog $csvPath
    Add-SnapshotLog $csvPath $snapshot
    $csv = Import-Csv -LiteralPath $csvPath
    Assert-True ($csv.CellID -eq '100' -and $csv.RSRP_dBm -eq '' -and $csv.RX_KBps -eq '' -and $csv.Error -match 'Traffic: counter unavailable') 'CSV serialization lost missing values or diagnostics.'
}
finally { Remove-Item -LiteralPath $csvPath }

# Keep modem-wide samples and visible gaps even when no LTE cell is reported.
$script:fixtureCells.ServingCellsLte = @()
$gap = Get-LteSnapshot $modem
Add-MonitorSnapshot $session $gap
Assert-True ($null -eq $gap.PrimaryCell -and $gap.SecondaryCells.Count -eq 0 -and $session.History.Rsrp.Count -eq 2) 'A missing serving cell lost the time slot.'
Assert-True ([double]::IsNaN($session.History.Rsrp[1]) -and $session.History.TempC[1] -eq 40 -and $null -eq $session.HandoverLog.Previous) 'Missing-cell handling lost temperature or kept the handover baseline.'
Assert-True ($null -eq (Get-SignalStatistic $session.History.Rsrp.ToArray())) 'Missing primary readings contaminated signal statistics.'
Assert-True ((Format-TrafficRate 0) -eq '0 B/s' -and (Format-TrafficRate $null) -eq 'n/a') 'Traffic formatting conflates zero and missing.'
Write-Output 'PASS: primary identity, missing measurements, carrier alignment, CSV, history and frame'

# Warning decisions survive changes to presentation labels in either direction.
function Get-ModemDeviceSummary {
    [pscustomobject]@{ RatConfig = $script:ratConfig; Model = 'Test' }
}
$script:ratConfig = [pscustomobject]@{ Allowed = 'Automatic'; AllowedRats = @('UMTS', 'LTE'); GsmBands = @(); UmtsBands = @(); LteBands = @(); NrBands = @() }
$session.Summary = Get-ModemSummary $null
$text = (Get-MonitorFrame $session $view 120).Body.Text -join "`n"
Assert-True ($session.Summary.LegacyAllowed -and $text -match '2G/3G enabled') 'The warning depends on a 2G/3G display label.'
$script:ratConfig.Allowed = '2G/3G disabled'
$script:ratConfig.AllowedRats = @('LTE', 'NR')
$session.Summary = Get-ModemSummary $null
$text = (Get-MonitorFrame $session $view 120).Body.Text -join "`n"
Assert-True (-not $session.Summary.LegacyAllowed -and $text -notmatch 'downgrade possible') 'Display text overrode normalized capabilities.'
Write-Output 'PASS: warning decisions are independent of display text'
