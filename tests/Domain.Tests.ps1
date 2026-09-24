# Hardware-free checks for the pure domain parsers: pwsh -NoProfile -File tests/Domain.Tests.ps1
# Fixtures quote the manuals / real output where noted; "synthetic" ones are built from the documented layout.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @(
    'src/domain/Signal.ps1', 'src/domain/Band.ps1', 'src/domain/CellMeasurement.ps1',
    'src/domain/ModemStatus.ps1', 'src/domain/QuectelStatus.ps1', 'src/domain/FibocomStatus.ps1',
    'src/domain/AtProfile.ps1', 'src/domain/Downgrade.ps1', 'src/infrastructure/Modem.ps1'
)) { . (Join-Path $root $file) }

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

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

# AT response text from lines (CRLF, final OK).
function New-AtResponse([string[]]$Line) { return ((@($Line) + 'OK') -join "`r`n") + "`r`n" }

function Get-AtProfile([string]$Id) { return $script:AtProfiles | Where-Object Id -EQ $Id }

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

# Intel XMM (L860-GL): real responses recorded in docs/neighbor-cells.md
$intel = @{
    'AT+MTSM=1' = New-AtResponse '+MTSM: 52'
    'AT+XCESQ?' = New-AtResponse '+XCESQ: 0,99,99,255,255,19,58,11,255,255,255,255'
    'AT+XLEC?'  = New-AtResponse '+XLEC: 0,2,3,5,BAND_LTE_18,0,0,0,0'
    'AT+XMCI=0' = New-AtResponse @(
        '+XMCI: 4,440,50,"0x8AA8","0x0558E901","0x019F","0x0000170C","0x00005D5C","0xFFFFFFFF",61,20,19,"0x00000002","0x00000000"'
        '+XMCI: 5,000,000,"0xFFFE","0xFFFFFFFF","0x0184","0x00009F8A","0xFFFFFFFF","0xFFFFFFFF",31,15,255,"0x7FFFFFFF","0x00000000"'
    )
}
$status = ConvertFrom-AtStatus (Get-AtProfile 'Intel') $intel
Assert-Equal 52 $status.TempC 'Intel temperature'
Assert-Equal 5.5 $status.Rssnr 'Intel RSSNR'
Assert-Equal @(10, 20) $status.Ca.BandwidthsMHz 'Intel CA bandwidths'
Assert-Equal 2 @($status.Cells).Count 'Intel XMCI cells'
Assert-Equal 1 @($status.Neighbors).Count 'Intel neighbors'
Assert-Equal -110 $status.Neighbors[0].RsrpDbm 'Intel neighbor RSRP'
Assert-Equal 40842 $status.Neighbors[0].Earfcn 'Intel neighbor EARFCN'
Assert-Equal 'B41/2500T' $status.Neighbors[0].Band 'Intel neighbor band'
$intel['AT+XMCI=0'] = "ERROR`r`n"
Assert-Equal $null (ConvertFrom-AtStatus (Get-AtProfile 'Intel') $intel).Neighbors 'Intel XMCI error must be unavailable'
$intel['AT+XMCI=0'] = New-AtResponse @()
Assert-Equal 0 @((ConvertFrom-AtStatus (Get-AtProfile 'Intel') $intel).Neighbors).Count 'Intel XMCI with no cells lists none'
# Shortened real response (the recorded one lists more bands).
$rat = ConvertFrom-AtConfig (Get-AtProfile 'Intel') @{ 'AT+XACT?' = New-AtResponse '+XACT: 4,2,1,1,2,4,5,8,101,103,118,141,171' }
Assert-Equal '3G+4G' $rat.Allowed 'XACT allowed'
Assert-Equal @(1, 3, 18, 41, 71) $rat.LteBands 'XACT LTE bands'
Write-Output 'PASS: Intel XMM profile (L860-GL responses)'

# Quectel RM5xx: manual V1.2 examples (5.12, 5.20, 12.5, 5.25); QCAINFO has no example -> synthetic
$quectel = @{
    'AT+QTEMP'                = New-AtResponse @('+QTEMP:"aoss0-usr","26"', '+QTEMP:"mdm-q6-usr","27"', '+QTEMP:"xo-therm-usr","24"', '+QTEMP:"sdx-case-therm-usr","31"')
    'AT+QCAINFO'              = New-AtResponse @(
        '+QCAINFO: "PCC",1650,100,"LTE BAND 3",1,12,-100,-12,-68,8'
        '+QCAINFO: "SCC",100,50,"LTE BAND 1",2,300,-95,-10,-70,5'
        '+QCAINFO: "SCC",500,25,"LTE BAND 1",0,301,-,-,-,-'
    )
    'AT+QSINR'                = New-AtResponse '+QSINR: -3,-7,-1,-2,LTE'
    'AT+QENG="servingcell"'   = New-AtResponse '+QENG: "servingcell","NOCONN","LTE","FDD",460,01,5F1EA15,12,1650,3,5,5,DE10,-100,-12,-68,11,0,-32768,27'
    'AT+QENG="neighbourcell"' = New-AtResponse @(
        '+QENG: "neighbourcell intra","LTE",38950,276,-3,-88,-65,0,37,7,16,6,44'
        '+QENG: "neighbourcell inter","LTE",39148,-,-,-,-,-,37,0,30,7,-,-,-,-'
        '+QENG: "neighbourcell inter","LTE",37900,-,-,-,-,-,0,0,30,6,-,-,-,-'
    )
}
$status = ConvertFrom-AtStatus (Get-AtProfile 'Quectel') $quectel
Assert-Equal 31 $status.TempC 'Quectel hottest sensor'
Assert-Equal 8.0 $status.Rssnr 'Quectel RSSNR from QCAINFO PCC'
Assert-Equal 2 $status.Ca.Cells 'Quectel CA cells (deconfigured SCC excluded)'
Assert-Equal @(20, 10) $status.Ca.BandwidthsMHz 'Quectel CA bandwidths from RBs'
Assert-Equal 1 @($status.Neighbors).Count 'Quectel measured neighbors'
Assert-Equal -88 $status.Neighbors[0].RsrpDbm 'Quectel neighbor RSRP (intra: RSRQ before RSRP)'
Assert-Equal -3 $status.Neighbors[0].RsrqDb 'Quectel neighbor RSRQ'
Assert-Equal 276 $status.Neighbors[0].Pci 'Quectel neighbor PCI'
$serving = @($status.Cells | Where-Object Role -EQ 'Serving')
Assert-Equal 1650 $serving[0].Earfcn 'Quectel serving EARFCN'
Assert-Equal 0x5F1EA15 $serving[0].CellId 'Quectel serving cell ID (hex)'
Assert-Equal 0xDE10 $serving[0].Tac 'Quectel serving TAC (hex)'
Assert-Equal -100 $serving[0].RsrpDbm 'Quectel serving RSRP'

$quectel.Remove('AT+QCAINFO')
$status = ConvertFrom-AtStatus (Get-AtProfile 'Quectel') $quectel
Assert-Equal (-3.0) $status.Rssnr 'Quectel RSSNR falls back to QSINR PRX'
Assert-Equal 1 $status.Ca.Cells 'Quectel single carrier without QCAINFO'
Assert-Equal @(20) $status.Ca.BandwidthsMHz 'Quectel DL bandwidth index 5 = 20 MHz'
Assert-Equal 30 (ConvertFrom-QtempResponse (New-AtResponse '+QTEMP: 30,28,27')) 'EM12/EG25 QTEMP layout (forum example)'

$endc = ConvertFrom-QengServingResponse (New-AtResponse @(
            '+QENG: "servingcell","NOCONN"'
            '+QENG: "LTE","FDD",460,01,5F1EA15,12,1650,3,5,5,DE10,-99,-12,-67,11,9,230,-'
            '+QENG:"NR5G-NSA",460,01,747,-71,13,-11,627264,78,12,1'
        ))
Assert-Equal 'LTE,NR' ($endc.Rat -join ',') 'Quectel EN-DC cells'
Assert-Equal 1650 $endc[0].Earfcn 'Quectel EN-DC LTE EARFCN (shifted layout)'
Assert-Equal -99 $endc[0].RsrpDbm 'Quectel EN-DC LTE RSRP'
Assert-Equal 627264 $endc[1].Channel 'Quectel EN-DC NR ARFCN'
$sa = ConvertFrom-QengServingResponse (New-AtResponse '+QENG: "servingcell","NOCONN","NR5G-SA","TDD", 460,01,9013B004,299,690E0F,633984,78,12,-107,-13,2,1,-')
Assert-Equal 'NR' $sa[0].Rat 'Quectel SA cell'
Assert-Equal 633984 $sa[0].Channel 'Quectel SA ARFCN'
# Synthetic, from the documented WCDMA layout.
$wcdma = ConvertFrom-QengServingResponse (New-AtResponse '+QENG: "servingcell","NOCONN","WCDMA",440,10,1234,ABCDEF,10700,300,0,-80,-5,-,-,-,-,-')
Assert-Equal 'UMTS' $wcdma[0].Rat 'Quectel WCDMA serving'
Assert-Equal 10700 $wcdma[0].Channel 'Quectel WCDMA UARFCN'
# Synthetic, WCDMA-mode LTE neighbor layout (RSRP before RSRQ).
$nb = ConvertFrom-QengNeighbourResponse (New-AtResponse '+QENG: "neighbourcell","LTE",1650,12,-95,-11,20')
Assert-Equal -95 $nb[0].RsrpDbm 'Quectel WCDMA-mode LTE neighbor RSRP'
Assert-Equal -11 $nb[0].RsrqDb 'Quectel WCDMA-mode LTE neighbor RSRQ'

$prefs = @{
    'AT+QNWPREFCFG="mode_pref"' = New-AtResponse '+QNWPREFCFG: "mode_pref",AUTO'
    'AT+QNWPREFCFG="gw_band"'   = New-AtResponse '+QNWPREFCFG: "gw_band",1:2:3:4:5:6:7:8:9:19'
    'AT+QNWPREFCFG="lte_band"'  = New-AtResponse '+QNWPREFCFG: "lte_band",1:3:8'
    'AT+QNWPREFCFG="nr5g_band"' = New-AtResponse '+QNWPREFCFG: "nr5g_band",1:3:7:20:28:40:41:71:77:78:79'
}
$rat = ConvertFrom-AtConfig (Get-AtProfile 'Quectel') $prefs
Assert-True ($rat.Allowed -match '3G') 'AUTO must report 3G as allowed'
Assert-Equal @(1, 3, 8) $rat.LteBands 'Quectel LTE bands'
Assert-Equal 11 @($rat.NrBands).Count 'Quectel NR bands'
Assert-Equal 10 @($rat.UmtsBands).Count 'Quectel WCDMA bands'
$prefs['AT+QNWPREFCFG="mode_pref"'] = New-AtResponse '+QNWPREFCFG: "mode_pref",LTE:NR5G'
Assert-Equal '4G+5G' (ConvertFrom-AtConfig (Get-AtProfile 'Quectel') $prefs).Allowed 'Quectel LTE:NR5G'
Write-Output 'PASS: Quectel profile (RM5xx manual examples)'

# Fibocom FM350: the "1,4,..." / "1,9,..." +GTCCINFO lines are real FM350 output (OpenWrt forum);
# the neighbor lines and the other commands are synthetic.
$fibocom = @{
    'AT+GTSENRDTEMP=1' = New-AtResponse '+GTSENRDTEMP: 1,45300'
    'AT+GTCAINFO?'     = New-AtResponse @('+GTCAINFO:', 'PCC:103,358,1300,100,2,1,3,2,60', 'SCC1:2,0,101,300,100,50,50,2,1,3,2,55')
    'AT+GTCCINFO?'     = New-AtResponse @(
        '+GTCCINFO:'
        'LTE service cell:'
        '1,4,262,1,05D5,0019BF801,1300,358,103,100,13,60,60,22'
        '1,9,,,FFFFFFF,00FFFFFFF,641760,940,5078,450,19,76,76,84'
        'LTE neighbor cell:'
        '2,4,262,1,05D5,0019BF802,1300,359,100,50,52,18'
        '2,2,262,1,1234,00ABCDE,10700,300,0,0,0,40,90,45,20'
    )
}
$status = ConvertFrom-AtStatus (Get-AtProfile 'FibocomGt') $fibocom
Assert-Equal 45.3 $status.TempC 'Fibocom temperature (milli-Celsius)'
Assert-Equal 6.5 $status.Rssnr 'Fibocom RSSNR (0.5 dB steps)'
Assert-Equal @(20, 10) $status.Ca.BandwidthsMHz 'Fibocom CA bandwidths'
$serving = @($status.Cells | Where-Object { $_.Rat -eq 'LTE' -and $_.Role -eq 'Serving' })
Assert-Equal -81 $serving[0].RsrpDbm 'Fibocom serving RSRP index 60'
Assert-Equal -9 $serving[0].RsrqDb 'Fibocom serving RSRQ index 22'
Assert-Equal 0x19BF801 $serving[0].CellId 'Fibocom cell ID (hex)'
Assert-Equal 1 @($status.Neighbors).Count 'Fibocom LTE neighbors'
Assert-Equal -89 $status.Neighbors[0].RsrpDbm 'Fibocom neighbor RSRP'
Assert-Equal 'B3/1800' $status.Neighbors[0].Band 'Fibocom neighbor band'
Assert-Equal 1 @($status.Cells | Where-Object Rat -EQ 'NR').Count 'Fibocom NR cell'
Assert-Equal 1 @($status.Cells | Where-Object Rat -EQ 'UMTS').Count 'Fibocom UMTS neighbor'
$fibocom.Remove('AT+GTCAINFO?')
Assert-Equal @(20) (ConvertFrom-AtStatus (Get-AtProfile 'FibocomGt') $fibocom).Ca.BandwidthsMHz 'Fibocom single carrier without GTCAINFO'
$rat = ConvertFrom-AtConfig (Get-AtProfile 'FibocomGt') @{ 'AT+GTACT?' = New-AtResponse '+GTACT: 17,6,,101,103,5078,50257,1' }
Assert-Equal '4G+5G' $rat.Allowed 'GTACT NR/LTE'
Assert-Equal '5G' $rat.Preferred 'GTACT preferred NR'
Assert-Equal @(1, 3) $rat.LteBands 'GTACT LTE bands'
Assert-Equal @(78, 257) $rat.NrBands 'GTACT NR bands ("50" + n)'
Assert-Equal @(1) $rat.UmtsBands 'GTACT UMTS band'
Assert-True ((ConvertFrom-GtactResponse (New-AtResponse '+GTACT: 20,6,3,0')).Allowed -match '3G') 'GTACT 20 includes 3G'
Write-Output 'PASS: Fibocom GT profile (FM350)'

# Downgrade: AT cells of every profile; NR is not legacy
$cells = @(
    [pscustomobject]@{ Rat = 'NR'; Role = 'Serving'; Channel = 627264 }
    [pscustomobject]@{ Rat = 'UMTS'; Role = 'Neighbor'; Channel = 10700 }
)
$finding = Get-DowngradeFinding -RegisteredDataClass 'Lte' -LegacyServingCount 0 -AtCells $cells -AtSource 'QENG'
Assert-Equal 'Warning' $finding.Level 'UMTS neighbor is a warning'
Assert-Equal 'UMTS neighbor ch:10700 (QENG)' ($finding.Reasons -join ';') 'NR must not be reported; source label'
$finding = Get-DowngradeFinding -RegisteredDataClass 'Lte' -LegacyServingCount 0 -AtCells $wcdma -AtSource 'QENG'
Assert-Equal 'Alert' $finding.Level 'UMTS serving is an alert'
Write-Output 'PASS: downgrade detection with vendor cell lists'

# MBIM AT framing (libmbim: Intel/Fibocom/Compal raw "<cmd>\r\n"; Quectel QDU UINT32 type + command)
Assert-Equal @(65, 84, 13, 10) (ConvertTo-MbimAtRequest 'Crlf' 'AT') 'CRLF framing'
Assert-Equal @(0, 0, 0, 0, 65, 84) (ConvertTo-MbimAtRequest 'Qdu' 'AT') 'QDU framing'
$ok = [byte[]](@(0, 0, 0, 0) + [Text.Encoding]::ASCII.GetBytes("+QTEMP: 30,28,27`r`n") + @(0, 0))
Assert-Equal 30 (ConvertFrom-QtempResponse (ConvertFrom-MbimAtResponse 'Qdu' $ok)) 'QDU status OK without final result code'
$fail = [byte[]](@(1, 0, 0, 0) + [Text.Encoding]::ASCII.GetBytes("`r`nOK`r`n"))
Assert-True ((ConvertFrom-MbimAtResponse 'Qdu' $fail) -notmatch '(?m)^OK') 'QDU failure status must not look like OK'
Assert-Equal "`r`nOK`r`n" (ConvertFrom-MbimAtResponse 'Crlf' ([Text.Encoding]::ASCII.GetBytes("`r`nOK`r`n"))) 'CRLF passthrough'
Write-Output 'PASS: MBIM AT framing'
