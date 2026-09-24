# Hardware-free checks for the pure domain parsers: pwsh -NoProfile -File tests/Domain.Tests.ps1
# Fixtures quote the manuals / real output where noted; "synthetic" ones are built from the documented layout.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @(
    'src/domain/Signal.ps1', 'src/domain/Band.ps1'
)) { . (Join-Path $root $file) }

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -is [array] -or $Actual -is [array]) {
        $e = @($Expected) -join ','
        $a = @($Actual) -join ','
        if ($e -ne $a) { throw "$Message (expected [$e], got [$a])" }
        return
    }
    if ($Expected -ne $Actual -or ($null -eq $Expected) -ne ($null -eq $Actual)) {
        throw "$Message (expected '$Expected', got '$Actual')"
    }
}

# EARFCN -> band (3GPP TS 36.101 Table 5.7.3-1)
$bands = [ordered]@{
    0 = 'B1/2100'; 599 = 'B1/2100'; 1300 = 'B3/1800'; 1500 = 'B3/1800'; 4800 = 'B11/1500'; 5100 = 'B12/700'
    5230 = 'B13/700'; 5330 = 'B14/700'; 5500 = 'B?/5500'; 5900 = 'B18/800'; 6100 = 'B19/800'; 6500 = 'B21/1500'
    7800 = 'B24/1600'; 8300 = 'B25/1900'; 8800 = 'B26/850'; 9460 = 'B28/700'; 39650 = 'B41/2500T'
    42000 = 'B42/3500T'; 44000 = 'B43/3700T'; 66500 = 'B66/AWS'; 68700 = 'B71/600'; 70000 = 'B?/70000'; -1 = 'B?/-1'
}
foreach ($case in $bands.GetEnumerator()) {
    Assert-Equal $case.Value (Get-EarfcnBand $case.Key) "EARFCN $($case.Key)"
}
Write-Output 'PASS: EARFCN band table'

# WinRT RSRP / RSRQ: MBIM spec dBm / dB and L860-GL 3GPP indices
Assert-Equal -100 (ConvertFrom-WinRtRsrp -100) 'Spec RSRP dBm'
Assert-Equal -140 (ConvertFrom-WinRtRsrp -140) 'Spec RSRP lower bound'
Assert-Equal -80 (ConvertFrom-WinRtRsrp 61) 'Index RSRP (L860-GL: 61 -> -80 dBm)'
Assert-Equal $null (ConvertFrom-WinRtRsrp $null) 'Missing RSRP must not become index 0'
Assert-Equal $null (ConvertFrom-WinRtRsrp 255) 'Invalid RSRP'
Assert-Equal $null (ConvertFrom-WinRtRsrp ([double][uint32]::MaxValue)) 'MBIM 0xFFFFFFFF RSRP'
Assert-Equal -12 (ConvertFrom-WinRtRsrq -12) 'Spec RSRQ dB'
Assert-Equal -10 (ConvertFrom-WinRtRsrq 20) 'Index RSRQ (20 -> -10 dB)'
Assert-Equal $null (ConvertFrom-WinRtRsrq -30) 'Out of range RSRQ'
Assert-Equal $null (ConvertFrom-WinRtRsrq $null) 'Missing RSRQ'
Write-Output 'PASS: WinRT RSRP/RSRQ normalization'
