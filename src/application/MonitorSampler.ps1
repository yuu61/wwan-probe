# Application: one reusable background runspace for blocking modem/counter reads.
# Only completed snapshots cross back to the UI; session/history/CSV stay on its thread.
function New-MonitorSampler {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    $pipeline = [powershell]::Create()
    try {
        $null = $pipeline.AddScript({
            param($SourceRoot)
            foreach ($file in @(
                'domain/Signal.ps1', 'domain/Band.ps1', 'domain/CellMeasurement.ps1',
                'domain/ModemStatus.ps1', 'domain/Downgrade.ps1',
                'infrastructure/WinRt.ps1', 'infrastructure/Modem.ps1',
                'infrastructure/PerfCounter.ps1', 'application/Snapshot.ps1'
            )) { . (Join-Path $SourceRoot $file) }
        }).AddArgument((Split-Path $PSScriptRoot -Parent))
        $null = $pipeline.Invoke()
        if ($pipeline.HadErrors) { throw $pipeline.Streams.Error[0] }
        $pipeline.Commands.Clear()
        return [pscustomobject]@{ Pipeline = $pipeline; Pending = $null }
    }
    catch {
        $pipeline.Dispose()
        throw
    }
}

function Start-MonitorSample {
    # Starts a read-only measurement; no external state is changed.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Sampler, $Modem)

    if ($null -ne $Sampler.Pending) { throw 'A sample is already in progress.' }
    $Sampler.Pipeline.Commands.Clear()
    $Sampler.Pipeline.Streams.Error.Clear()
    $null = $Sampler.Pipeline.AddCommand('Get-LteSnapshot').AddArgument($Modem)
    $Sampler.Pending = $Sampler.Pipeline.BeginInvoke()
}

function Receive-MonitorSample($Sampler) {
    if ($null -eq $Sampler.Pending -or -not $Sampler.Pending.IsCompleted) {
        throw 'The sample is not complete.'
    }
    try {
        $result = $Sampler.Pipeline.EndInvoke($Sampler.Pending)
        if ($Sampler.Pipeline.HadErrors) { throw $Sampler.Pipeline.Streams.Error[0] }
        if ($result.Count -ne 1) { throw 'Expected one completed snapshot.' }
        return $result[0]
    }
    finally { $Sampler.Pending = $null }
}

function Remove-MonitorSampler {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Sampler)

    if ($null -eq $Sampler) { return }
    try { $Sampler.Pipeline.Stop() }
    finally { $Sampler.Pipeline.Dispose() }
}
