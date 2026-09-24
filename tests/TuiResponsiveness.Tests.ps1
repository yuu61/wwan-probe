# Hardware-free regression checks: pwsh -NoProfile -File tests/TuiResponsiveness.Tests.ps1
# Use a real sampling runspace and simulated console input/output.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @(
    'src/application/MonitorSession.ps1', 'src/application/MonitorSampler.ps1',
    'src/application/SnapshotLog.ps1', 'src/infrastructure/CsvFile.ps1',
    'src/presentation/Frame.ps1', 'src/presentation/TuiMonitor.ps1'
)) { . (Join-Path $root $file) }

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-TestSession([int]$Count = 0, [int]$Interval = 0) {
    [pscustomobject]@{
        Modem = $null; Snapshot = $null; Iteration = 0; HistoryMax = 600
        Config = [pscustomobject]@{ Count = $Count; Interval = $Interval; CsvPath = '' }
        History = New-SignalHistory
        HandoverLog = New-HandoverLog
        DowngradeLog = [pscustomobject]@{ AlertCount = 0; WarningCount = 0 }
    }
}

function New-TestView {
    @{
        Paused = $false; Fetching = $false; Done = $false; Quit = $false
        RefreshRequested = $true; Dirty = $true; ChartRows = 2
        ChartVisible = New-ChartVisibility
    }
}

function New-TestSampler([int]$DelayMs = 600) {
    $sampler = New-MonitorSampler
    $sampler.Pipeline.Runspace.SessionStateProxy.SetVariable('TestDelayMs', $DelayMs)
    $null = $sampler.Pipeline.AddScript({
        function Get-LteSnapshot($Modem) {
            Start-Sleep -Milliseconds $TestDelayMs
            [pscustomobject]@{
                Timestamp = 'test'; Serving = @([pscustomobject]@{ RsrpDbm = -90; RsrqDb = -10 })
                Rssnr = 10; RxKB = 1; TxKB = 2; TempC = 30; Downgrade = $null
            }
        }
    }).Invoke()
    return $sampler
}

function Read-TuiKey {
    if ($script:keys.Count -gt 0) { return $script:keys.Dequeue() }
}
function Test-WindowResized { return $false }
function Show-TuiScreen($Session, $View) { & $script:onFrame $Session $View }
function Add-TestKey([ConsoleKey]$Key, [char]$Character = [char]0) {
    $script:keys.Enqueue([ConsoleKeyInfo]::new($Character, $Key, $false, $false, $false))
}
$script:keys = [Collections.Generic.Queue[ConsoleKeyInfo]]::new()

# Arrow repeats, visibility, pause and refresh must be processed before the first
# slow sample finishes. Quit also must return from the UI loop while it is pending.
$sampler = New-TestSampler -DelayMs 2000
try {
    $session = New-TestSession
    $view = New-TestView
    $script:frames = 0
    $script:onFrame = {
        param($Session, $View)
        $script:frames++
        if ($script:frames -eq 1) {
            Add-TestKey UpArrow
            Add-TestKey UpArrow
            Add-TestKey DownArrow
            Add-TestKey D1 '1'
            Add-TestKey P 'p'
            Add-TestKey R 'r'
        }
        else {
            Assert-True ($View.ChartRows -eq 3 -and -not $View.ChartVisible['1']) 'Chart input was lost.'
            Assert-True ($View.Paused -and $View.Fetching) 'Pause did not apply during sampling.'
            Assert-True ($Session.Iteration -eq 0) 'Input waited for sample completion.'
            Assert-True (-not $View.RefreshRequested) 'Refresh queued a duplicate sample.'
            Add-TestKey Q 'q'
        }
    }
    Invoke-TuiLoop $session $view $sampler
    Assert-True ($script:frames -eq 2) 'Queued keys caused redundant redraws.'
    Assert-True (-not $sampler.Pending.IsCompleted) 'Quit waited for the sample.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: input and quit during slow sampling; coalesced redraw'

# A paused in-flight result is committed once; explicit refresh still works while
# paused, and resume bypasses the otherwise long sampling interval.
$sampler = New-TestSampler -DelayMs 100
$csvPath = [IO.Path]::GetTempFileName()
try {
    $session = New-TestSession -Count 3 -Interval 60
    $session.Config.CsvPath = $csvPath
    Initialize-SnapshotLog $csvPath
    $view = New-TestView
    $script:stage = 0
    $script:onFrame = {
        param($Session, $View)
        if ($script:stage -eq 0) { Add-TestKey P 'p'; $script:stage = 1 }
        elseif ($script:stage -eq 1 -and $Session.Iteration -eq 1) {
            Assert-True ($View.Paused -and -not $View.Fetching) 'Pause started another sample.'
            Add-TestKey R 'r'; $script:stage = 2
        }
        elseif ($script:stage -eq 2 -and $Session.Iteration -eq 2) {
            Assert-True ($View.Paused -and -not $View.Fetching) 'Refresh resumed automatic sampling.'
            Add-TestKey P 'p'; $script:stage = 3
        }
    }
    Invoke-TuiLoop $session $view $sampler
    Assert-True ($view.Done -and $session.Iteration -eq 3) 'Count was not respected.'
    Assert-True ($session.History.Rsrp.Count -eq 3) 'History lost or duplicated a sample.'
    Assert-True ($null -eq $sampler.Pending) 'An extra sample was started after Count.'
    $rows = @(Import-Csv -LiteralPath $csvPath)
    Assert-True ($rows.Count -eq 3 -and $rows[0].RSRP_dBm -eq '-90') 'CSV lost or corrupted samples.'
}
finally {
    Remove-MonitorSampler $sampler
    Remove-Item -LiteralPath $csvPath
}
Write-Output 'PASS: pause, refresh, resume, history, CSV and Count'

# Interval=0 must keep sampling, but never start concurrent requests.
$sampler = New-TestSampler -DelayMs 50
try {
    $session = New-TestSession -Count 2
    $view = New-TestView
    $script:onFrame = { param($Session, $View) }
    Invoke-TuiLoop $session $view $sampler
    Assert-True ($session.Iteration -eq 2 -and $session.History.Rsrp.Count -eq 2) 'Interval=0 failed.'
    Start-MonitorSample $sampler $null
    $rejected = $false
    try { Start-MonitorSample $sampler $null } catch { $rejected = $true }
    Assert-True $rejected 'Concurrent sampling was accepted.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: back-to-back sampling and concurrency guard'

# Worker errors must be surfaced, and the pending invocation must be released.
$sampler = New-TestSampler
try {
    $sampler.Pipeline.Commands.Clear()
    $null = $sampler.Pipeline.AddScript('function Get-LteSnapshot($Modem) { throw "test failure" }').Invoke()
    Start-MonitorSample $sampler $null
    while (-not $sampler.Pending.IsCompleted) { Start-Sleep -Milliseconds 25 }
    $reported = $false
    try { Receive-MonitorSample $sampler } catch { $reported = $_.Exception.Message -match 'test failure' }
    Assert-True $reported 'Worker error was swallowed.'
    Assert-True ($null -eq $sampler.Pending) 'Failed invocation was not released.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: worker error propagation and cleanup'
