# Hardware-free regression checks: pwsh -NoProfile -File tests/Handover.Tests.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @(
    'src/domain/Signal.ps1', 'src/domain/Band.ps1', 'src/domain/Downgrade.ps1',
    'src/application/Snapshot.ps1', 'src/application/MonitorSession.ps1',
    'src/presentation/Gauge.ps1', 'src/presentation/Frame.ps1', 'src/presentation/TuiMonitor.ps1'
)) { . (Join-Path $root $file) }

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-TestSnapshot([long]$CellId = 100, [string]$Provider = '44010') {
    [pscustomobject]@{
        Timestamp = '2026-09-24 12:34:56'; Error = $null; Downgrade = $null
        Serving = @(); Umts = @(); Neighbors = @(); ProviderId = $Provider
        PrimaryCell = [pscustomobject]@{
            Provider = $Provider; CellId = $CellId; Band = 'B1'; Earfcn = 100
            Pci = 10; Tac = 20; RsrpDbm = -90
        }
    }
}

$log = New-HandoverLog -MaxEntries 3
$sample = New-TestSnapshot
Add-HandoverLog $log $sample
Assert-True ($log.Count -eq 0) 'Initial observation must not be a handover.'
$sample.PrimaryCell.Pci = 11
$sample.PrimaryCell.Tac = 21
$sample.PrimaryCell.RsrpDbm = -100
Add-HandoverLog $log $sample
Assert-True ($log.Count -eq 0) 'Metadata changes must not be counted.'
$next = New-TestSnapshot 200
Add-HandoverLog $log $next
Assert-True ($log.Count -eq 1 -and $log.Entries[0].From.CellId -eq 100 -and $log.Entries[0].To.CellId -eq 200) 'Cell change was not recorded.'
Assert-True ($log.Entries[0].From.RsrpDbm -eq -100 -and $log.Entries[0].Timestamp -eq $next.Timestamp) 'Event must use the latest preceding measurement and detection time.'
$next.PrimaryCell.CellId = 999
Assert-True ($log.Entries[0].To.CellId -eq 200) 'Recorded event was mutated.'
Add-HandoverLog $log (New-TestSnapshot 200 '44020')
Add-HandoverLog $log (New-TestSnapshot 100)
Add-HandoverLog $log (New-TestSnapshot 200)
Assert-True ($log.Count -eq 4 -and $log.Entries.Count -eq 3 -and $log.Entries[0].Number -eq 2) 'PLMN changes, return transitions or retention failed.'
Write-Output 'PASS: initial baseline, identity, metadata, immutable events, return transitions and bounded retention'

foreach ($kind in 'error', 'absent', 'invalid', 'missing-id', 'missing-provider') {
    $log = New-HandoverLog
    Add-HandoverLog $log (New-TestSnapshot)
    $gap = New-TestSnapshot 200
    switch ($kind) {
        error { $gap.Error = 'sample failed' }
        absent { $gap.PrimaryCell = $null }
        invalid { $gap.PrimaryCell.CellId = [uint32]::MaxValue }
        missing-id { $gap.PrimaryCell.CellId = $null }
        missing-provider { $gap.PrimaryCell.Provider = '' }
    }
    Add-HandoverLog $log $gap
    Add-HandoverLog $log (New-TestSnapshot 300)
    Assert-True ($log.Count -eq 0) "Gap '$kind' produced a false handover."
    Add-HandoverLog $log (New-TestSnapshot 400)
    Assert-True ($log.Count -eq 1) "Detection did not resume after '$kind'."
}
Write-Output 'PASS: errors, missing cells and invalid identities reset the baseline'

# Exercise the real snapshot builder: invalid RSRP must not promote a CA SCell
# into the primary-cell identity used for handover detection.
function Get-ModemCellsInfo { return $script:cells }
function Get-AdapterTraffic { return @{ BwMbps = 0; RxKB = 0; TxKB = 0 } }
function Get-AtStatus { return $script:atStatus }
$script:atStatus = @{ Cells = @(); Neighbors = @(); TempC = $null; Rssnr = $null; Ca = $null }
$primary = [pscustomobject]@{
    ReferenceSignalReceivedPowerInDBm = 255; ReferenceSignalReceivedQualityInDBm = 255
    ChannelNumber = 100; PhysicalCellId = 10; CellId = 100; TrackingAreaCode = 20
    TimingAdvanceInBitPeriods = 0; ProviderId = '44010'
}
$secondary = $primary.PSObject.Copy()
$secondary.ReferenceSignalReceivedPowerInDBm = 50
$secondary.CellId = 200
$script:cells = @{ ServingCellsLte = @($primary, $secondary) }
$modem = @{ CurrentNetwork = @{ RegisteredProviderId = '44010'; RegisteredDataClass = 'Lte' } }
$log = New-HandoverLog
$snapshot = Get-LteSnapshot $modem
Assert-True (-not $snapshot.Error -and $snapshot.PrimaryCell.CellId -eq 100 -and $null -eq $snapshot.PrimaryCell.RsrpDbm) 'Unmeasured primary identity was lost.'
Add-HandoverLog $log $snapshot
$secondary.CellId = 300
Add-HandoverLog $log (Get-LteSnapshot $modem)
$script:cells.ServingCellsLte = @($primary)
Add-HandoverLog $log (Get-LteSnapshot $modem)
Assert-True ($log.Count -eq 0) 'CA secondary changes produced a false handover.'
$primary.CellId = 400
Add-HandoverLog $log (Get-LteSnapshot $modem)
Assert-True ($log.Count -eq 1) 'Primary change with missing RSRP was not detected.'
Write-Output 'PASS: snapshot identity is independent of RSRP and CA secondary cells'

# A modem following the MBIM spec reports dBm / dB, and may list neighbors in WinRT.
$specCell = [pscustomobject]@{
    ReferenceSignalReceivedPowerInDBm = -97; ReferenceSignalReceivedQualityInDBm = -11
    ChannelNumber = 9460; PhysicalCellId = 5; CellId = 500; TrackingAreaCode = 30
    TimingAdvanceInBitPeriods = 0; ProviderId = '44020'
}
$winRtNeighbor = [pscustomobject]@{
    ReferenceSignalReceivedPowerInDBm = -105; ReferenceSignalReceivedQualityInDBm = -14
    ChannelNumber = 1500; PhysicalCellId = 77; CellId = 4294967295; TrackingAreaCode = 30; ProviderId = '44020'
}
$script:cells = @{ ServingCellsLte = @($specCell); NeighboringCellsLte = @($winRtNeighbor) }
$script:atStatus = @{ Cells = $null; Neighbors = $null; TempC = $null; Rssnr = $null; Ca = $null }
$snapshot = Get-LteSnapshot $modem
Assert-True ($snapshot.Serving.Count -eq 1 -and $snapshot.Serving[0].RsrpDbm -eq -97 -and $snapshot.Serving[0].RsrqDb -eq -11) 'Spec dBm serving cell was dropped.'
Assert-True ($snapshot.Serving[0].Band -eq 'B28/700' -and $snapshot.PrimaryCell.RsrpDbm -eq -97) 'Spec serving cell identity is wrong.'
Assert-True ($snapshot.Neighbors.Count -eq 1 -and $snapshot.Neighbors[0].RsrpDbm -eq -105 -and $snapshot.Neighbors[0].Band -eq 'B3/1800') 'WinRT neighbor fallback failed.'
$script:atStatus = @{ Cells = @(); Neighbors = @(); TempC = $null; Rssnr = $null; Ca = $null }
Assert-True ((Get-LteSnapshot $modem).Neighbors.Count -eq 0) 'An AT neighbor list (even empty) must take precedence.'
Write-Output 'PASS: MBIM-spec signal units and WinRT neighbor fallback'

# Commit samples through the same use case as both monitor loops.
function Get-ModemSummary { return @{ Model = 'Test'; RatConfig = $null } }
$session = Initialize-MonitorSession $null ([pscustomobject]@{ CsvPath = ''; Count = 0; Interval = 0 })
for ($i = 0; $i -le 12; $i++) { Add-MonitorSnapshot $session (New-TestSnapshot (100 + $i)) }
Assert-True ($session.Iteration -eq 13 -and $session.HandoverLog.Count -eq 12) 'Sample commit did not update handover history.'
$view = @{ Unicode = $false; ChartVisible = New-ChartVisibility; ChartRows = 2; LastHeight = 24 }
$frame = Get-MonitorFrame $session $view 120
$text = $frame.Body.Text -join "`n"
Assert-True ($text -match 'Handover history \(12\)' -and $text -match 'Switched to CellID:112 B1 PCI:10' -and $text -notmatch 'CellID:109\b') 'Compact history must show the latest three destinations.'
Assert-True ($text -notmatch 'From:|To:|->') 'Compact history must not display transition chains.'

$script:keys = [Collections.Generic.Queue[ConsoleKeyInfo]]::new()
function Read-TuiKey { if ($script:keys.Count) { $script:keys.Dequeue() } }
function Add-TestKey([ConsoleKey]$Key) { $script:keys.Enqueue([ConsoleKeyInfo]::new([char]0, $Key, $false, $false, $false)) }
Add-TestKey H
Read-TuiInput $view
$frame = Get-MonitorFrame $session $view 120
$text = $frame.Body.Text -join "`n"
Assert-True ($view.HandoverVisible -and $text -match '#12 2026-09-24 12:34:56 Switched to CellID:112' -and $text -match 'B1 PCI:10 PLMN:44010 EARFCN:100 TAC:20 RSRP:-90dBm') 'History toggle or destination details failed.'
Assert-True ($text -notmatch 'From:|To:|->') 'Detailed history must not display transition chains.'
Assert-True ($frame.Body.Count -le 23) 'History page does not fit the terminal.'
Add-TestKey DownArrow
Read-TuiInput $view
Assert-True ($view.HandoverOffset -eq 1 -and $view.ChartRows -eq 2) 'History scrolling changed chart height.'
$view.HandoverOffset = 10000
$frame = Get-MonitorFrame $session $view 120
Assert-True (($frame.Body.Text -join "`n") -match '#1 2026-09-24') 'Oldest retained event is inaccessible.'
Add-TestKey H
Read-TuiInput $view
Assert-True (-not $view.HandoverVisible) 'Cannot return to the monitor.'
$view.HandoverVisible = $true
$session.HandoverLog = New-HandoverLog
$frame = Get-MonitorFrame $session $view 80
Assert-True (($frame.Body.Text -join "`n") -match 'no LTE cell changes') 'Empty history is not explained.'
Write-Output 'PASS: sample integration, compact frame, details, keyboard navigation, page bounds and empty history'
