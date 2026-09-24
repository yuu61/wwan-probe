#Requires -Version 7.4
# Downloads the Windows SDK WinRT projection (CsWinRT) that lte_monitor.ps1 needs
# and extracts the two required DLLs into .\lib.
# PowerShell 7 (.NET) cannot load WinRT types by itself; the package targets net8.0,
# hence PowerShell 7.4 or later.
# Usage: .\setup.ps1 [-Force]

param([switch]$Force)

$ErrorActionPreference = 'Stop'
$package = 'microsoft.windows.sdk.net.ref'
$version = '10.0.26100.81'
$entries = @('lib/net8.0/WinRT.Runtime.dll', 'lib/net8.0/Microsoft.Windows.SDK.NET.dll')
$libDir = Join-Path $PSScriptRoot 'lib'

$targets = $entries | ForEach-Object { Join-Path $libDir (Split-Path $_ -Leaf) }
if (-not $Force -and -not ($targets | Where-Object { -not (Test-Path $_) })) {
    Write-Output "Already set up: $libDir (use -Force to re-download)"
    return
}

$url = "https://api.nuget.org/v3-flatcontainer/$package/$version/$package.$version.nupkg"
$nupkg = Join-Path ([IO.Path]::GetTempPath()) "$package.$version.nupkg"
Write-Output "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $nupkg

New-Item -ItemType Directory -Force -Path $libDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($nupkg)
try {
    foreach ($name in $entries) {
        $entry = $zip.GetEntry($name)
        if (-not $entry) { throw "Entry not found in package: $name" }
        $dest = Join-Path $libDir (Split-Path $name -Leaf)
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
        Write-Output "Extracted $dest"
    }
}
finally {
    $zip.Dispose()
    Remove-Item $nupkg -ErrorAction SilentlyContinue
}
