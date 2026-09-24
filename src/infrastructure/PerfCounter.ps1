# Infrastructure: Network interface performance counters.

# Single Get-Counter call; it blocks ~1s for rate counters.
function Get-AdapterTraffic([string]$InstanceName = 'Generic Mobile Broadband Adapter') {
    $result = [pscustomobject]@{ BwMbps = $null; RxKB = $null; TxKB = $null; Error = $null }
    try {
        $paths = @(
            "\Network Interface($InstanceName)\Current Bandwidth",
            "\Network Interface($InstanceName)\Bytes Received/sec",
            "\Network Interface($InstanceName)\Bytes Sent/sec"
        )
        $samples = (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples
        foreach ($s in $samples) {
            # PDH_CSTATUS_VALID_DATA (0) and PDH_CSTATUS_NEW_DATA (1) are both usable.
            if ($s.Status -notin 0, 1 -or $null -eq $s.CookedValue -or
                [double]::IsNaN($s.CookedValue) -or [double]::IsInfinity($s.CookedValue)) { continue }
            if ($s.Path -like '*\current bandwidth') { $result.BwMbps = [math]::Round($s.CookedValue / 1e6, 1) }
            elseif ($s.Path -like '*\bytes received/sec') { $result.RxKB = [math]::Round($s.CookedValue / 1024, 1) }
            elseif ($s.Path -like '*\bytes sent/sec') { $result.TxKB = [math]::Round($s.CookedValue / 1024, 1) }
        }
        if ($null -eq $result.BwMbps -or $null -eq $result.RxKB -or $null -eq $result.TxKB) {
            $result.Error = 'One or more traffic counters are unavailable'
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    return $result
}
