# Usage: ./tool.ps1 lint | ./tool.ps1 format [-Check]
# format writes UTF-8 files; format -Check only reports files needing formatting.
param(
    [Parameter(Mandatory)][ValidateSet('lint', 'format')][string]$Task,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$tests = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'tests') -Filter '*.ps1' -File -Recurse)
$targets = @(
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'src') -Filter '*.ps1' -File -Recurse
    Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'diagnostics') -Filter '*.ps1' -File -Recurse
    Get-Item -LiteralPath (Join-Path $PSScriptRoot 'lte_monitor.ps1')
    $tests
)

if ($Task -eq 'lint') {
    # Tests call Assert-* with positional arguments and build in-memory fixtures with New-* helpers.
    $testOptions = @{ ExcludeRule = 'PSAvoidUsingPositionalParameters', 'PSUseShouldProcessForStateChangingFunctions' }
    $findings = @($targets | ForEach-Object {
            $options = if ($_.FullName -in $tests.FullName) { $testOptions } else { @{} }
            Invoke-ScriptAnalyzer -Path $_.FullName @options
        })
    if ($findings.Count -gt 0) {
        $findings | Out-Host
        throw "Lint failed: $($findings.Count) finding(s)."
    }
    Write-Output 'Lint passed.'
    return
}

# Every rule Invoke-Formatter can fix (PSScriptAnalyzer 1.24). Settings are inline to avoid
# relying on the module's default settings file in an offline OneDrive folder.
# Kept for the existing style: one-line blocks ({ return $x }), "}" and "else" on separate
# lines, and hashtable "=" left to PSAlignAssignmentStatement.
$settings = @{
    IncludeRules = @(
        'PSPlaceOpenBrace', 'PSPlaceCloseBrace',
        'PSUseConsistentIndentation', 'PSUseConsistentWhitespace',
        'PSAlignAssignmentStatement', 'PSUseCorrectCasing',
        'PSAvoidUsingCmdletAliases', 'PSAvoidUsingDoubleQuotesForConstantString',
        'PSAvoidTrailingWhitespace', 'PSAvoidExclaimOperator',
        'PSAvoidSemicolonsAsLineTerminators'
    )
    Rules = @{
        PSPlaceOpenBrace = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSPlaceCloseBrace = @{ Enable = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $true }
        PSUseConsistentIndentation = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        PSUseConsistentWhitespace = @{
            Enable = $true; CheckOpenBrace = $true; CheckInnerBrace = $true; CheckPipe = $true
            CheckPipeForRedundantWhitespace = $true; CheckOpenParen = $true; CheckOperator = $true
            CheckSeparator = $true; CheckParameter = $true; IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement = @{ Enable = $true; CheckHashtable = $true }
        PSUseCorrectCasing = @{ Enable = $true; CheckCommands = $true; CheckKeyword = $true; CheckOperator = $true }
        PSAvoidUsingCmdletAliases = @{ Enable = $true }
        PSAvoidUsingDoubleQuotesForConstantString = @{ Enable = $true }
        PSAvoidExclaimOperator = @{ Enable = $true }
        PSAvoidSemicolonsAsLineTerminators = @{ Enable = $true }
    }
}
$changed = 0
foreach ($file in $targets) {
    $source = Get-Content -LiteralPath $file.FullName -Raw
    if ([string]::IsNullOrEmpty($source)) { continue }
    # PSPlaceCloseBrace leaves a space where it breaks "... } }" and PSAvoidTrailingWhitespace
    # does not remove it, so strip trailing whitespace afterwards (no here-strings in targets).
    $formatted = (Invoke-Formatter -ScriptDefinition $source -Settings $settings) -replace '(?m)[ \t]+(?=\r?$)', ''
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
Write-Output "Format: $changed file(s) $(if ($Check) { 'need formatting' } else { 'formatted' })."
