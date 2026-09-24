# Infrastructure: WinRT type loading and async bridging.
# Requires Windows PowerShell 5.1 (WinRT type loading).

[Windows.Networking.NetworkOperators.MobileBroadbandModem, Windows.Networking.NetworkOperators, ContentType = WindowsRuntime] | Out-Null
Add-Type -AssemblyName System.Runtime.WindowsRuntime

$script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]

# Helper: Await WinRT async
function Wait-WinRtAsync($AsyncOp, [Type]$ResultType, [int]$TimeoutMs = 10000) {
    $asTask = $script:AsTaskGeneric.MakeGenericMethod($ResultType)
    $task = $asTask.Invoke($null, @($AsyncOp))
    if (-not $task.Wait($TimeoutMs)) { throw "WinRT async operation timed out (${TimeoutMs}ms)" }
    return $task.Result
}
