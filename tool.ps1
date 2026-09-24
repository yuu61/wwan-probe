# Usage: ./tool.ps1 lint | ./tool.ps1 format [-Check]
# PowerShell: PSScriptAnalyzer. C# (the Add-Type sources): Roslyn analyzers and dotnet format
# through tools/csharp/WwanProbe.csproj, which needs the .NET 10 SDK (global.json) and lib/
# from setup.ps1.
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
$csproj = Join-Path $PSScriptRoot 'tools/csharp/WwanProbe.csproj'

# Runs dotnet and returns its exit code; the project references the WinRT projection in lib/.
function Invoke-DotNet([string[]]$Arguments) {
    if (-not (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'The .NET 10 SDK (dotnet) is required for the C# sources.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib/Microsoft.Windows.SDK.NET.dll'))) {
        throw 'lib/ is missing. Run ./setup.ps1 first.'
    }
    # dotnet writes UTF-8 even on a Japanese (CP932) console, so decode its output as UTF-8.
    # global.json (SDK 10) is looked up from the working directory, not from the project.
    $encoding = [Console]::OutputEncoding
    Push-Location -LiteralPath $PSScriptRoot
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        & dotnet @Arguments | Out-Host
        return $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $encoding
        Pop-Location
    }
}

if ($Task -eq 'lint') {
    # Tests call Assert-* with positional arguments and build in-memory fixtures with New-* helpers.
    $testOptions = @{ ExcludeRule = 'PSAvoidUsingPositionalParameters', 'PSUseShouldProcessForStateChangingFunctions' }
    $findings = @($targets | ForEach-Object {
            $options = if ($_.FullName -in $tests.FullName) { $testOptions } else { @{} }
            Invoke-ScriptAnalyzer -Path $_.FullName @options
        })
    if ($findings.Count -gt 0) { $findings | Out-Host }
    # Analyzer and code style warnings are errors (TreatWarningsAsErrors in the project).
    $csharpFailed = (Invoke-DotNet 'build', $csproj, '--no-incremental', '-nologo', '-v', 'q') -ne 0
    if ($findings.Count -gt 0 -or $csharpFailed) {
        throw "Lint failed: $($findings.Count) PowerShell finding(s), C# analyzers $(if ($csharpFailed) { 'reported errors' } else { 'OK' })."
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

# Whitespace and code style only: analyzer code fixes (dotnet format analyzers) can change
# behavior, e.g. P/Invoke marshalling, so they are left to lint. Exit code 2 = changes needed.
$csharpFailed = $false
foreach ($pass in 'whitespace', 'style') {
    $arguments = @('format', $pass, $csproj) + $(if ($Check) { '--verify-no-changes' } else { @() })
    $exitCode = Invoke-DotNet $arguments
    if ($Check -and $exitCode -eq 2) { $csharpFailed = $true }
    elseif ($exitCode -ne 0) { throw "dotnet format $pass failed (exit code $exitCode)." }
}
if ($Check -and ($changed -gt 0 -or $csharpFailed)) {
    throw "Format check failed: $changed PowerShell file(s), C# sources $(if ($csharpFailed) { 'need formatting' } else { 'OK' })."
}
Write-Output "Format: $changed PowerShell file(s) $(if ($Check) { 'need formatting' } else { 'formatted' }); C# $(if ($Check) { 'checked' } else { 'formatted' })."
