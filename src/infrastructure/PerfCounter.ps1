# Infrastructure: Network interface performance counters.

# Single Get-Counter call; it blocks ~1s for rate counters.
function Get-AdapterTraffic([string]$InstanceName = 'Generic Mobile Broadband Adapter') {
    $result = [pscustomobject]@{ BwMbps = 0; RxKB = 0; TxKB = 0 }
    try {
        $paths = @(
            "\Network Interface($InstanceName)\Current Bandwidth",
            "\Network Interface($InstanceName)\Bytes Received/sec",
            "\Network Interface($InstanceName)\Bytes Sent/sec"
        )
        $samples = (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples
        foreach ($s in $samples) {
            if ($s.Path -like '*\current bandwidth') { $result.BwMbps = [math]::Round($s.CookedValue / 1e6, 1) }
            elseif ($s.Path -like '*\bytes received/sec') { $result.RxKB = [math]::Round($s.CookedValue / 1024, 1) }
            elseif ($s.Path -like '*\bytes sent/sec') { $result.TxKB = [math]::Round($s.CookedValue / 1024, 1) }
        }
    }
    catch {
        Write-Verbose "Get-AdapterTraffic: $($_.Exception.Message)"
    }
    return $result
}
