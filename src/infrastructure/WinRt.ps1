# Infrastructure: WinRT type loading and async bridging.
# PowerShell 7 (.NET) has no built-in WinRT support, so the CsWinRT projection
# assemblies (downloaded by setup.ps1) are loaded explicitly.

function Import-WinRtProjection([string]$LibDir) {
    foreach ($dll in 'WinRT.Runtime.dll', 'Microsoft.Windows.SDK.NET.dll') {
        $path = Join-Path $LibDir $dll
        if (-not (Test-Path $path)) { throw "WinRT projection not found: $path (run setup.ps1 first)" }
        Add-Type -Path $path
    }
}

# Helper: Await WinRT async (IAsyncOperation<T>)
function Wait-WinRtAsync($AsyncOp, [int]$TimeoutMs = 10000) {
    $task = [System.WindowsRuntimeSystemExtensions]::AsTask($AsyncOp)
    return Wait-TaskResult -Start { $task }.GetNewClosure() -TimeoutMs $TimeoutMs
}

# Returns the result of the first completed task started by $Start (a scriptblock returning a Task);
# a faulted task rethrows. $Start runs once, and once more if nothing has completed after
# $ResendAfterMs; both tasks are then awaited until $TimeoutMs in total. Nothing is cancelled.
function Wait-TaskResult([scriptblock]$Start, [int]$TimeoutMs, [int]$ResendAfterMs = [int]::MaxValue) {
    $tasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    $tasks.Add((& $Start))
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        foreach ($t in $tasks) {
            if (-not $t.IsCompleted) { continue }
            # Wait(0) rethrows a fault even when the task completed before the loop.
            $null = $t.Wait(0)
            return $t.Result
        }
        $elapsed = $timer.ElapsedMilliseconds
        if ($elapsed -ge $TimeoutMs) { throw "WinRT async operation timed out (${TimeoutMs}ms)" }
        if ($tasks.Count -eq 1 -and $elapsed -ge $ResendAfterMs) {
            $tasks.Add((& $Start))
            continue
        }
        # Short waits let PowerShell stop the sampling runspace promptly on quit.
        $wait = [math]::Min(50, $TimeoutMs - $elapsed)
        if ($tasks.Count -eq 1) { $wait = [math]::Min($wait, $ResendAfterMs - $elapsed) }
        $null = [System.Threading.Tasks.Task]::WaitAny($tasks.ToArray(), [int]$wait)
    }
}
