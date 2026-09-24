# Infrastructure: CSV file writing.
# UTF-8 with BOM so Excel does not misread it as the ANSI code page (pwsh's 'UTF8' has no BOM).

function Initialize-CsvFile([string]$Path, [string]$Header) {
    $Header | Out-File -FilePath $Path -Encoding utf8BOM
}

function Add-CsvLine([string]$Path, [string]$Line) {
    $Line | Out-File -FilePath $Path -Append -Encoding utf8BOM
}
