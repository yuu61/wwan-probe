# Infrastructure: Mobile broadband modem access via WinRT.
# Depends on WinRt.ps1 (Import-WinRtProjection must have been called).

function Get-DefaultModem {
    return [Windows.Networking.NetworkOperators.MobileBroadbandModem]::GetDefault()
}

function Get-ModemCellsInfo($Network) {
    $asyncOp = $Network.GetCellsInfoAsync()
    return Wait-WinRtAsync $asyncOp
}

# Vendor MBIM device services that carry AT commands, in probe order (libmbim data/mbim-service-*.json,
# src/libmbim-glib/mbim-uuid.c and mbim-cid.h). The modem's COM ports may be held by a driver, so AT
# commands go over MBIM when the firmware offers one of these. Only the L860-GL (Intel) was tested.
#   Verb    = MBIM command type used by libmbim / mbimcli for the AT command
#   Framing = 'Crlf': request is "<cmd>\r\n" as ASCII, response is the raw AT response text
#             'Qdu':  request is UINT32 CommandType (0 = AT) + "<cmd>", response is UINT32 status (0 = OK) + text
$script:MbimAtChannels = @(
    [pscustomobject]@{ Name = 'Intel AT Tunnel'; ServiceId = [guid]'da138c64-6515-4893-92b2-a1e1ca7c81ca'; Cid = [uint32]1; Verb = 'Set'; Framing = 'Crlf' }
    [pscustomobject]@{ Name = 'Fibocom AT'; ServiceId = [guid]'ffffffff-abca-4b11-a4e2-f2fc87f94488'; Cid = [uint32]1; Verb = 'Set'; Framing = 'Crlf' }
    [pscustomobject]@{ Name = 'Compal AT'; ServiceId = [guid]'a2a32a97-cab1-4f57-9ae1-451c74dda957'; Cid = [uint32]1; Verb = 'Query'; Framing = 'Crlf' }
    # Quectel QDU is a firmware update service; only CID 8 (COMMAND) is ever sent.
    [pscustomobject]@{ Name = 'Quectel QDU'; ServiceId = [guid]'6427015f-579d-48f5-8c54-f43ed1e76f83'; Cid = [uint32]8; Verb = 'Set'; Framing = 'Qdu' }
)

# AT channel over a serial (COM) port, for modems whose driver exposes a free AT port.
function New-SerialAtChannel {
    # Pure factory (no state change), ShouldProcess is not applicable.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([string]$PortName)

    return [pscustomobject]@{ Name = "Serial $PortName"; Port = $PortName }
}

# Finds the first MBIM AT channel that answers "AT" with OK, or $null. $Tried receives one
# "<name>: <reason>" line per rejected candidate (for diagnostics).
function Find-ModemAtChannel($Modem, [System.Collections.Generic.List[string]]$Tried, [int]$TimeoutMs = 1500) {
    foreach ($channel in $script:MbimAtChannels) {
        try {
            # Sent twice at most: the first response after the process starts using a service can be lost.
            $response = $null
            for ($try = 0; $try -lt 2 -and $null -eq $response; $try++) {
                $response = (Invoke-ModemAtCommand $Modem $channel -Command 'AT' -TimeoutMs $TimeoutMs)['AT']
            }
            if ($response -match '(?m)^OK\s*$') { return $channel }
            $reason = if ($null -eq $response) { 'no response' } else { 'no OK' }
        }
        catch {
            $reason = $_.Exception.Message
        }
        if ($null -ne $Tried) { $Tried.Add("$($channel.Name): $reason") }
    }
    return $null
}

# Sends the commands in order over one session of $Channel. Returns @{ <command> = <raw response text> }
# (including the final "OK"/"ERROR"). A command whose MBIM status is not success maps to $null;
# after a timeout the remaining commands are skipped (also $null) so a stuck modem does not stall every call.
function Invoke-ModemAtCommand($Modem, $Channel, [string[]]$Command, [int]$TimeoutMs = 3000) {
    if ($null -eq $Channel) { throw 'No AT channel' }
    if ($Channel.Port) { return Invoke-SerialAtCommand -PortName $Channel.Port -Command $Command -TimeoutMs $TimeoutMs }

    $service = $Modem.GetDeviceService($Channel.ServiceId)
    if (-not $service) { throw "$($Channel.Name) device service not available" }
    # PowerShell's binder cannot pass/receive CsWinRT IBuffer objects directly; go through reflection.
    $method = if ($Channel.Verb -eq 'Query') { 'SendQueryCommandAsync' } else { 'SendSetCommandAsync' }
    $send = [Windows.Networking.NetworkOperators.MobileBroadbandDeviceServiceCommandSession].GetMethod($method)
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
                (ConvertTo-MbimAtRequest $Channel.Framing $cmd))
            try {
                $result = Wait-WinRtAsync ($send.Invoke($session, [object[]]@($Channel.Cid, $request))) $TimeoutMs
            }
            catch {
                break
            }
            $text = $null
            if ($result.StatusCode -eq 0) {
                $buffer = $responseData.GetValue($result)
                $bytes = if ($buffer) { $toArray.Invoke($null, [object[]]@($buffer)) } else { [byte[]]@() }
                $text = ConvertFrom-MbimAtResponse $Channel.Framing $bytes
            }
            $responses[$cmd] = $text
        }
    }
    finally {
        $session.CloseSession()
    }
    return $responses
}

function ConvertTo-MbimAtRequest([string]$Framing, [string]$Command) {
    if ($Framing -eq 'Qdu') {
        # mbimcli --quectel-set-command sends the command without a line terminator.
        return [byte[]]([BitConverter]::GetBytes([uint32]0) + [Text.Encoding]::ASCII.GetBytes($Command))
    }
    return [Text.Encoding]::ASCII.GetBytes("$Command`r`n")
}

# Response bytes -> AT response text. For QDU the status word decides the final result code
# when the text itself carries none (undocumented whether it does), so the parsers can rely on it.
function ConvertFrom-MbimAtResponse([string]$Framing, [byte[]]$Bytes) {
    if ($Framing -ne 'Qdu') { return [Text.Encoding]::ASCII.GetString($Bytes) }
    if ($Bytes.Count -lt 4) { return $null }
    $status = [BitConverter]::ToUInt32($Bytes, 0)
    $text = [Text.Encoding]::ASCII.GetString($Bytes, 4, $Bytes.Count - 4).TrimEnd([char]0)
    if ($text -notmatch '(?m)^(OK|ERROR|\+CME ERROR:.*)\s*$') {
        $text += if ($status -eq 0) { "`r`nOK`r`n" } else { "`r`nERROR`r`n" }
    }
    elseif ($status -ne 0 -and $text -match '(?m)^OK\s*$') {
        $text = $text -replace '(?m)^OK(\s*)$', 'ERROR$1'
    }
    return $text
}

# Same contract as Invoke-ModemAtCommand over a COM port (opened for this call only).
function Invoke-SerialAtCommand([string]$PortName, [string[]]$Command, [int]$TimeoutMs) {
    $responses = @{}
    foreach ($cmd in $Command) { $responses[$cmd] = $null }
    $port = [System.IO.Ports.SerialPort]::new($PortName, 115200)
    $port.NewLine = "`r`n"
    $port.ReadTimeout = 100
    $port.Open()
    try {
        $port.DiscardInBuffer()
        foreach ($cmd in $Command) {
            $port.Write("$cmd`r")
            $text = [Text.StringBuilder]::new()
            $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
            $done = $false
            while (-not $done -and [DateTime]::UtcNow -lt $deadline) {
                try { $line = $port.ReadLine() }
                catch [System.TimeoutException] { continue }
                $null = $text.Append($line).Append("`r`n")
                $done = $line -match '^(OK|ERROR|\+CME ERROR:.*|\+CMS ERROR:.*)\s*$'
            }
            if (-not $done) { break }
            $responses[$cmd] = $text.ToString()
        }
    }
    finally {
        $port.Close()
        $port.Dispose()
    }
    return $responses
}
