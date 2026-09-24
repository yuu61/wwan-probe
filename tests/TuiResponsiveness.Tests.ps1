# Hardware-free regression checks: pwsh -NoProfile -File tests/TuiResponsiveness.Tests.ps1
# Use a real sampling runspace and simulated console input/output.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'src/Load.ps1')

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
                    Timestamp = 'test'; Serving = @(); PrimaryCell = [pscustomobject]@{ RsrpDbm = -90; RsrqDb = -10 }; SecondaryCells = @()
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

# Uppercase R resets the statistics at once, even during sampling, without a refresh;
# the in-flight sample then starts the new history. Lowercase r refreshes and keeps them.
$sampler = New-TestSampler -DelayMs 300
try {
    $session = New-TestSession -Interval 60
    $session.Iteration = 2
    foreach ($series in $session.History.Values) { $series.Add(1); $series.Add(2) }
    $session.HandoverLog.Entries.Add([pscustomobject]@{ Number = 5 })
    $session.HandoverLog.Count = 5
    $session.DowngradeLog.AlertCount = 3
    $view = New-TestView
    $view.HandoverOffset = 4
    $script:stage = 0
    $script:onFrame = {
        param($Session, $View)
        if ($script:stage -eq 0) { Add-TestKey R 'R'; $script:stage = 1 }
        elseif ($script:stage -eq 1) {
            $emptied = @($Session.History.Values | Where-Object { $_.Count -gt 0 }).Count -eq 0
            Assert-True ($emptied -and $Session.HandoverLog.Count -eq 0 -and $Session.HandoverLog.Entries.Count -eq 0) 'Reset kept history.'
            Assert-True ($Session.DowngradeLog.AlertCount -eq 0 -and $View.HandoverOffset -eq 0) 'Reset kept the 2G/3G log or page.'
            Assert-True ($Session.Iteration -eq 2 -and $View.Fetching -and -not $View.RefreshRequested) 'Reset changed progress or sampling.'
            $script:stage = 2
        }
        elseif ($script:stage -eq 2 -and $Session.Iteration -eq 3) {
            Assert-True ($Session.History.Rsrp.Count -eq 1 -and $Session.History.TempC.Count -eq 1) 'In-flight sample was not kept after reset.'
            Add-TestKey R 'r'; $script:stage = 3
        }
        elseif ($script:stage -eq 3 -and $Session.Iteration -eq 4) {
            Assert-True ($Session.History.Rsrp.Count -eq 2) 'Lowercase r reset the statistics.'
            Add-TestKey Q 'q'
        }
    }
    Invoke-TuiLoop $session $view $sampler
    Assert-True ($script:stage -eq 3 -and $session.Iteration -eq 4) 'Reset or refresh sequence did not complete.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: R resets statistics during sampling; r only refreshes'

# Interval=0 must keep sampling, but never start concurrent requests.
$sampler = New-TestSampler -DelayMs 50
try {
    $session = New-TestSession -Count 2
    $view = New-TestView
    $script:onFrame = { }
    Invoke-TuiLoop $session $view $sampler
    Assert-True ($session.Iteration -eq 2 -and $session.History.Rsrp.Count -eq 2) 'Interval=0 failed.'
    Start-MonitorSample $sampler $null
    $rejected = $false
    try { Start-MonitorSample $sampler $null } catch { $rejected = $true }
    Assert-True $rejected 'Concurrent sampling was accepted.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: back-to-back sampling and concurrency guard'

# A caught cmdlet error can set HadErrors without leaving an error record.
# Both this snapshot and a subsequent sample must still reach the UI.
$sampler = New-TestSampler -DelayMs 0
try {
    $sampler.Pipeline.Commands.Clear()
    $null = $sampler.Pipeline.AddScript({
            $script:OriginalSnapshot = ${function:Get-LteSnapshot}
            function Get-LteSnapshot {
                # The swallowed error is the case under test.
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingEmptyCatchBlock', '')]
                param($Modem)
                try { Get-Item -LiteralPath 'MissingMonitorTestDrive:/missing' -ErrorAction Stop }
                catch { }
                & $script:OriginalSnapshot $Modem
            }
        }).Invoke()
    $session = New-TestSession -Count 2
    $view = New-TestView
    $script:onFrame = { }
    Invoke-TuiLoop $session $view $sampler
    Assert-True $sampler.Pipeline.HadErrors 'The handled cmdlet error was not reproduced.'
    Assert-True ($sampler.Pipeline.Streams.Error.Count -eq 0) 'Handled error escaped into the error stream.'
    Assert-True ($session.Iteration -eq 2 -and $session.History.Rsrp.Count -eq 2) 'Handled error interrupted sampling.'
    Assert-True ($null -eq $sampler.Pending) 'Completed invocation was not released.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: handled worker errors do not interrupt sampling'

# An unhandled nonterminating error must still be reported even with a snapshot.
$sampler = New-TestSampler -DelayMs 0
try {
    $sampler.Pipeline.Commands.Clear()
    $null = $sampler.Pipeline.AddScript({
            $script:OriginalSnapshot = ${function:Get-LteSnapshot}
            function Get-LteSnapshot($Modem) {
                Write-Error 'nonterminating test failure' -ErrorAction Continue
                & $script:OriginalSnapshot $Modem
            }
        }).Invoke()
    Start-MonitorSample $sampler $null
    while (-not $sampler.Pending.IsCompleted) { Start-Sleep -Milliseconds 25 }
    $reported = $false
    try { $null = Receive-MonitorSample $sampler }
    catch { $reported = $_.Exception.Message -match 'nonterminating test failure' }
    Assert-True $reported 'Nonterminating worker error was swallowed.'
    Assert-True ($null -eq $sampler.Pending) 'Failed invocation was not released.'
}
finally { Remove-MonitorSampler $sampler }
Write-Output 'PASS: nonterminating worker error propagation and cleanup'

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
