# Infrastructure: Mobile broadband modem access via WinRT.
# Depends on WinRt.ps1 (Import-WinRtProjection must have been called).

function Get-DefaultModem {
    return [Windows.Networking.NetworkOperators.MobileBroadbandModem]::GetDefault()
}

function Get-ModemCellsInfo($Network) {
    $asyncOp = $Network.GetCellsInfoAsync()
    return Wait-WinRtAsync $asyncOp
}

# Intel AT Tunnel MBIM device service (libmbim: MBIM_SERVICE_INTEL_AT_TUNNEL, CID 1 = AT_COMMAND).
# Sends AT commands over MBIM; the modem's COM ports are held by the ModemControl driver.
$script:IntelAtTunnelServiceId = [guid]'da138c64-6515-4893-92b2-a1e1ca7c81ca'
$script:IntelAtTunnelAtCommandCid = [uint32]1

# Returns the raw AT response text (including the final "OK"/"ERROR").
function Invoke-ModemAtCommand($Modem, [string]$Command) {
    $service = $Modem.GetDeviceService($script:IntelAtTunnelServiceId)
    if (-not $service) { throw "Intel AT Tunnel device service not available" }
    $session = $service.OpenCommandSession()
    try {
        $request = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer(
            [Text.Encoding]::ASCII.GetBytes("$Command`r`n"))
        # PowerShell's binder cannot pass/receive CsWinRT IBuffer objects directly; go through reflection.
        $send = [Windows.Networking.NetworkOperators.MobileBroadbandDeviceServiceCommandSession].GetMethod('SendSetCommandAsync')
        $result = Wait-WinRtAsync ($send.Invoke($session, [object[]]@($script:IntelAtTunnelAtCommandCid, $request)))
        if ($result.StatusCode -ne 0) { throw ("AT command failed: status 0x{0:X8}" -f $result.StatusCode) }
        $response = [Windows.Networking.NetworkOperators.MobileBroadbandDeviceServiceCommandResult].GetProperty('ResponseData').GetValue($result)
        if (-not $response) { return "" }
        $toArray = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions].GetMethod('ToArray', [type[]]@([Windows.Storage.Streams.IBuffer]))
        return [Text.Encoding]::ASCII.GetString($toArray.Invoke($null, [object[]]@($response)))
    }
    finally {
        $session.CloseSession()
    }
}
