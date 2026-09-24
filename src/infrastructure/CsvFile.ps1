# Infrastructure: CSV file writing.
# UTF-8 with BOM so Excel does not misread it as the ANSI code page (pwsh's 'UTF8' has no BOM).

# RFC 4180 field: quoted only when it contains a comma, quote or line break; $null -> empty.
function ConvertTo-CsvField($Value) {
    if ($null -eq $Value) { return '' }
    $s = [string]$Value
    if ($s -match '[",\r\n]') { return '"' + $s.Replace('"', '""') + '"' }
    return $s
}

function Initialize-CsvFile([string]$Path, [string[]]$Columns) {
    ($Columns | ForEach-Object { ConvertTo-CsvField $_ }) -join ',' |
        Out-File -FilePath $Path -Encoding utf8BOM
}

function Add-CsvRow([string]$Path, [object[]]$Fields) {
    ($Fields | ForEach-Object { ConvertTo-CsvField $_ }) -join ',' |
        Out-File -FilePath $Path -Append -Encoding utf8BOM
}
