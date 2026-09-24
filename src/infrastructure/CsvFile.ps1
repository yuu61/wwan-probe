# Infrastructure: CSV file writing.

function Initialize-CsvFile([string]$Path, [string]$Header) {
    $Header | Out-File -FilePath $Path -Encoding UTF8
}

function Add-CsvLine([string]$Path, [string]$Line) {
    $Line | Out-File -FilePath $Path -Append -Encoding UTF8
}
