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

# Sends the commands in order over one AT Tunnel session. Returns @{ <command> = <raw response text> }
# (including the final "OK"/"ERROR"). A command whose MBIM status is not success maps to $null;
# after a timeout the remaining commands are skipped (also $null) so a stuck modem does not stall every call.
function Invoke-ModemAtCommand($Modem, [string[]]$Command, [int]$TimeoutMs = 3000) {
    $service = $Modem.GetDeviceService($script:IntelAtTunnelServiceId)
    if (-not $service) { throw "Intel AT Tunnel device service not available" }
    # PowerShell's binder cannot pass/receive CsWinRT IBuffer objects directly; go through reflection.
    $send = [Windows.Networking.NetworkOperators.MobileBroadbandDeviceServiceCommandSession].GetMethod('SendSetCommandAsync')
    $responseData = [Windows.Networking.NetworkOperators.MobileBroadbandDeviceServiceCommandResult].GetProperty('ResponseData')
    $toArray = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions].GetMethod('ToArray', [type[]]@([Windows.Storage.Streams.IBuffer]))

    $responses = @{}
    $session = $service.OpenCommandSession()
    try {
        foreach ($cmd in $Command) {
            $responses[$cmd] = $null
        }
        foreach ($cmd in $Command) {
            $request = [System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions]::AsBuffer(
                [Text.Encoding]::ASCII.GetBytes("$cmd`r`n"))
            try {
                $result = Wait-WinRtAsync ($send.Invoke($session, [object[]]@($script:IntelAtTunnelAtCommandCid, $request))) $TimeoutMs
            }
            catch {
                break
            }
            $text = $null
            if ($result.StatusCode -eq 0) {
                $buffer = $responseData.GetValue($result)
                $text = if ($buffer) { [Text.Encoding]::ASCII.GetString($toArray.Invoke($null, [object[]]@($buffer))) } else { "" }
            }
            $responses[$cmd] = $text
        }
    }
    finally {
        $session.CloseSession()
    }
    return $responses
}
