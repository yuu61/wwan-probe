# Hardware-free regression checks: pwsh -NoProfile -File tests/BandHighlight.Tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Load.ps1')

function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function New-TestCell([string]$Band, [int]$Earfcn, [int]$Pci) {
    [pscustomobject]@{ Band = $Band; Earfcn = $Earfcn; Pci = $Pci }
}

$rat = [pscustomobject]@{ LteBands = @(1, 2, 3); NrBands = @(78) }
$serving = New-TestCell 'B2/1900' 600 0
$snapshot = [pscustomobject]@{
    Serving   = @($serving)
    Neighbors = @(
        $serving # Same cell reported by both sources must count only once.
        New-TestCell 'B2/1900' 600 1
        foreach ($pci in 0..4) { New-TestCell 'B3/1800' 1200 $pci }
        New-TestCell 'B?/99999' 99999 1
        $null
    )
}
$line = Get-LteBandLine $rat $snapshot
Assert-True ($line.Text -ceq ' LTE bands: B1 B2 B3   NR bands: n78') 'Band labels or NR suffix changed.'
Assert-True (($line.Segments | Where-Object Text -EQ 'B1').Color -eq 'DarkGray' -and $null -eq ($line.Segments | Where-Object Text -EQ 'B1').GrayLevel) 'Zero cells must keep the default color.'
Assert-True (($line.Segments | Where-Object Text -EQ 'B2').GrayLevel -eq 172) 'Two distinct cells must be dimmer than five, despite duplicate reports.'
Assert-True (($line.Segments | Where-Object Text -EQ 'B3').GrayLevel -eq 255) 'The most observed band must be white.'
Assert-True ($line.Segments[-1].Color -eq 'DarkGray' -and $null -eq $line.Segments[-1].GrayLevel) 'NR suffix must retain its default color.'

# PCI can repeat on another frequency; zero is a valid EARFCN and PCI.
$snapshot.Serving = @(New-TestCell 'B1/2100' 0 0)
$snapshot.Neighbors = @(
    New-TestCell 'B1/2100' 0 0
    New-TestCell 'B1/2100' 1 0
    New-TestCell 'B1/2100' 1 1
)
$updated = Get-LteBandLine $rat $snapshot
Assert-True (($updated.Segments | Where-Object Text -EQ 'B1').GrayLevel -eq 255) 'Distinct EARFCN/PCI pairs must count separately.'
Assert-True ($null -eq ($updated.Segments | Where-Object Text -EQ 'B3').GrayLevel) 'Old observations must not remain highlighted.'
$snapshot.Neighbors = $null
$updated = Get-LteBandLine $rat $snapshot
Assert-True (($updated.Segments | Where-Object Text -EQ 'B1').GrayLevel -eq 255) 'A lone serving cell must be white when neighbor data is unavailable.'
foreach ($empty in @($null, @{ Serving = @(); Neighbors = @() })) {
    $updated = Get-LteBandLine $rat $empty
    Assert-True (@($updated.Segments | Where-Object { $_.Color -ne 'DarkGray' -or $null -ne $_.GrayLevel }).Count -eq 0) 'Missing observations must keep all bands at the default color.'
}

# Regression: one and two cells must have a large brightness difference.
$smallRat = [pscustomobject]@{ LteBands = @(1, 18); NrBands = @() }
$smallSnapshot = @{
    Serving   = @(New-TestCell 'B1/2100' 0 0)
    Neighbors = @(
        New-TestCell 'B18/800' 5850 1
        New-TestCell 'B18/800' 5850 2
        foreach ($pci in 0..9) { New-TestCell 'B3/1800' 1200 $pci }
    )
}
$smallLine = Get-LteBandLine $smallRat $smallSnapshot
Assert-True (($smallLine.Segments | Where-Object Text -EQ 'B1').GrayLevel -eq 144) 'One cell must use medium gray when another displayed band has two.'
Assert-True (($smallLine.Segments | Where-Object Text -EQ 'B18').GrayLevel -eq 255) 'Two cells must be white; unlisted bands must not dim displayed bands.'
$smallSnapshot.Neighbors = @(New-TestCell 'B18/800' 5850 1)
$equalLine = Get-LteBandLine $smallRat $smallSnapshot
Assert-True (@($equalLine.Segments | Where-Object GrayLevel -EQ 255).Count -eq 2) 'Equal counts must have equal brightness.'

# Segmented lines must preserve clipping/padding and plain output without escapes.
$original = [Console]::Out
$writer = [IO.StringWriter]::new()
try {
    [Console]::SetOut($writer)
    foreach ($width in @(0, 13, 15, 80)) {
        $null = $writer.GetStringBuilder().Clear()
        Write-ConsoleLine -Text $line.Text -Color $line.Color -Width $width -Segments $line.Segments
        $expected = if ($width -lt $line.Text.Length) { $line.Text.Substring(0, $width) } else { $line.Text.PadRight($width) }
        $visible = $writer.ToString() -replace '\x1b\[[0-9;]*m', ''
        Assert-True ($visible -ceq $expected) "Segmented output must fit width $width without counting color escapes."
    }
    $null = $writer.GetStringBuilder().Clear()
    Write-ConsoleLine -Text $smallLine.Text -Color $smallLine.Color -Width 80 -Segments $smallLine.Segments
    Assert-True ($writer.ToString().Contains("`e[38;2;144;144;144mB1`e[39m")) 'B1 must render medium gray and then reset its color.'
    Assert-True ($writer.ToString().Contains("`e[38;2;255;255;255mB18`e[39m")) 'B18 must render white and then reset its color.'
    $null = $writer.GetStringBuilder().Clear()
    Show-PlainFrame ([pscustomobject]@{ Body = @($line) })
    Assert-True ($writer.ToString() -ceq ($line.Text + [Environment]::NewLine + [Environment]::NewLine)) 'Plain output must preserve text without color escapes.'
}
finally {
    [Console]::SetOut($original)
    $writer.Dispose()
}
Write-Output 'PASS: band brightness, duplicate cells, missing observations, refresh, clipping and plain output'
