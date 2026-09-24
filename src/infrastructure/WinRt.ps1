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
    # Short waits let PowerShell stop the sampling runspace promptly on quit.
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not $task.IsCompleted) {
        $remaining = $TimeoutMs - $timer.ElapsedMilliseconds
        if ($remaining -le 0) { throw "WinRT async operation timed out (${TimeoutMs}ms)" }
        $null = $task.Wait([int][math]::Min(50, $remaining))
    }
    # Preserve exception propagation even when the task completed before the loop.
    $null = $task.Wait(0)
    return $task.Result
}
