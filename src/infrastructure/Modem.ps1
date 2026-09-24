# Infrastructure: Mobile broadband modem access via WinRT.
# Depends on WinRt.ps1 (Import-WinRtProjection must have been called).

function Get-DefaultModem {
    return [Windows.Networking.NetworkOperators.MobileBroadbandModem]::GetDefault()
}

function Get-ModemCellsInfo($Network) {
    $asyncOp = $Network.GetCellsInfoAsync()
    return Wait-WinRtAsync $asyncOp
}
