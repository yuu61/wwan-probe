# Usage: . ./tool.ps1; lint; format -Check
# format writes UTF-8 files; format -Check only reports files needing formatting.
function lint {
    $ErrorActionPreference = 'Stop'
    $findings = @(
        Invoke-ScriptAnalyzer -Path (Join-Path $PSScriptRoot 'src') -Recurse
        Invoke-ScriptAnalyzer -Path (Join-Path $PSScriptRoot 'lte_monitor.ps1')
    )
    if ($findings.Count -gt 0) {
        $findings | Out-Host
        throw "Lint failed: $($findings.Count) finding(s)."
    }
}

function format {
    param([switch]$Check)

    $ErrorActionPreference = 'Stop'
    # Avoid relying on the module's default settings file in an offline OneDrive folder.
    $settings = @{
        IncludeRules = @(
            'PSPlaceOpenBrace', 'PSPlaceCloseBrace',
            'PSUseConsistentIndentation', 'PSUseConsistentWhitespace',
            'PSAlignAssignmentStatement'
        )
        Rules = @{
            PSPlaceOpenBrace = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
            PSPlaceCloseBrace = @{ Enable = $true; NewLineAfter = $false; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $false }
            PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
            PSUseConsistentWhitespace = @{ Enable = $true; CheckOpenBrace = $true; CheckInnerBrace = $true; CheckPipe = $true; CheckSeparator = $true; CheckOperator = $true; CheckOpenParen = $true }
            PSAlignAssignmentStatement = @{ Enable = $true; CheckHashtable = $true }
        }
    }
    $files = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' -File -Recurse) +
        @(Get-Item -LiteralPath (Join-Path $PSScriptRoot 'lte_monitor.ps1'))
    $changed = 0
    foreach ($file in $files) {
        $source = Get-Content -LiteralPath $file.FullName -Raw
        if ([string]::IsNullOrEmpty($source)) { continue }
        $formatted = Invoke-Formatter -ScriptDefinition $source -Settings $settings
        if ($source -ceq $formatted) { continue }
        $changed++
        if ($Check) {
            Write-Output "Needs formatting: $($file.FullName)"
        }
        else {
            Set-Content -LiteralPath $file.FullName -Value $formatted -NoNewline -Encoding utf8NoBOM
            Write-Output "Formatted: $($file.FullName)"
        }
    }
    if ($Check -and $changed -gt 0) { throw "Format check failed: $changed file(s)." }
}
