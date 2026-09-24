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
    if (-not $task.Wait($TimeoutMs)) { throw "WinRT async operation timed out (${TimeoutMs}ms)" }
    return $task.Result
}
