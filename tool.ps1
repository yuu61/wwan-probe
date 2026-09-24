# Usage: ./tool.ps1 lint | ./tool.ps1 format [-Check]
# PowerShell (every .ps1 in the repository): PSScriptAnalyzer. C# (the Add-Type sources): Roslyn
# analyzers and dotnet format through tools/csharp/WwanProbe.csproj, which needs the .NET 10 SDK
# (global.json) and lib/ from setup.ps1.
# format writes UTF-8 files; format -Check only reports files needing formatting.
param(
    [Parameter(Mandatory)][ValidateSet('lint', 'format')][string]$Task,
    [switch]$Check
)

$ErrorActionPreference = 'Stop'
$csproj = Join-Path $PSScriptRoot 'tools/csharp/WwanProbe.csproj'
if (-not (Get-Command dotnet -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'The .NET 10 SDK (dotnet) is required for the C# sources.'
}
# The project references the WinRT projection in lib/.
if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'lib/Microsoft.Windows.SDK.NET.dll'))) {
    throw 'lib/ is missing. Run ./setup.ps1 first.'
}

function Get-RepoPath([string]$Path) { return [IO.Path]::GetRelativePath($PSScriptRoot, $Path) }

# Invoke-ScriptAnalyzer and Invoke-Formatter (PSUseCorrectCasing) look up every command name.
# Functions defined in other files are not found, and each such lookup searches every PATH
# directory for every PATHEXT extension and every module path: 10-20 s per task here.
# Only the built-in commands (PSHOME) are visible while they run, which also keeps the results
# independent of PATH and of installed modules not already imported into the session.
# Commands from other modules (e.g. the Windows NetAdapter or PnpDevice modules) become unknown
# to the command-based rules (PSAvoidUsingCmdletAliases, PSUseCmdletCorrectly,
# PSAvoidUsingPositionalParameters, PSUseCorrectCasing); the sources use none today. Add their
# module path here if they do.
function Invoke-WithBuiltInCommand([scriptblock]$Script) {
    # PSScriptAnalyzer itself may be installed outside PSHOME, so load it before narrowing.
    Import-Module PSScriptAnalyzer
    $path, $modulePath = $env:PATH, $env:PSModulePath
    try {
        $env:PATH = $PSHOME
        $env:PSModulePath = Join-Path $PSHOME 'Modules'
        & $Script
    }
    finally {
        $env:PATH, $env:PSModulePath = $path, $modulePath
    }
}

# Runs dotnet with each argument list in turn in a background process, so the PowerShell work
# can run meanwhile; Receive-Job returns one result per list. The process keeps the environment
# it started with, so Invoke-WithBuiltInCommand narrowing PATH does not affect it. global.json
# (SDK 10) is looked up from the working directory, not from the project.
function Invoke-DotNetJob([string[][]]$Commands) {
    return Start-Job -WorkingDirectory $PSScriptRoot {
        # dotnet writes UTF-8 even on a Japanese (CP932) console.
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $using:Commands | ForEach-Object {
            $output = dotnet @_ 2>&1 | ForEach-Object { "$_" }
            [pscustomobject]@{ Name = $_[1]; ExitCode = $LASTEXITCODE; Output = $output -join "`n" }
        }
    }
}

if ($Task -eq 'lint') {
    # Analyzer and code style warnings are errors (TreatWarningsAsErrors in the project).
    $build = Invoke-DotNetJob (, @('build', $csproj, '--no-incremental', '-nologo', '-v', 'q'))
    $findings = @(Invoke-WithBuiltInCommand { Invoke-ScriptAnalyzer -Path $PSScriptRoot -Recurse })
    if ($findings.Count -gt 0) { $findings | Out-Host }
    $result = Receive-Job $build -Wait -AutoRemoveJob
    if ($result.Output) { $result.Output | Out-Host }
    if ($findings.Count -gt 0 -or $result.ExitCode -ne 0) {
        $problems = @(
            if ($findings.Count -gt 0) { "$($findings.Count) PowerShell finding(s)" }
            if ($result.ExitCode -ne 0) { 'C# analyzer errors' }
        )
        throw "Lint failed: $($problems -join ' and ') (details above)."
    }
    Write-Output 'Lint passed: no PowerShell findings or C# analyzer errors.'
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
    Rules        = @{
        PSPlaceOpenBrace                          = @{ Enable = $true; OnSameLine = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true }
        PSPlaceCloseBrace                         = @{ Enable = $true; NewLineAfter = $true; IgnoreOneLineBlock = $true; NoEmptyLineBefore = $true }
        PSUseConsistentIndentation                = @{ Enable = $true; Kind = 'space'; IndentationSize = 4; PipelineIndentation = 'IncreaseIndentationForFirstPipeline' }
        PSUseConsistentWhitespace                 = @{
            Enable = $true; CheckOpenBrace = $true; CheckInnerBrace = $true; CheckPipe = $true
            CheckPipeForRedundantWhitespace = $true; CheckOpenParen = $true; CheckOperator = $true
            CheckSeparator = $true; CheckParameter = $true; IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement                = @{ Enable = $true; CheckHashtable = $true }
        PSUseCorrectCasing                        = @{ Enable = $true; CheckCommands = $true; CheckKeyword = $true; CheckOperator = $true }
        PSAvoidUsingCmdletAliases                 = @{ Enable = $true }
        PSAvoidUsingDoubleQuotesForConstantString = @{ Enable = $true }
        PSAvoidExclaimOperator                    = @{ Enable = $true }
        PSAvoidSemicolonsAsLineTerminators        = @{ Enable = $true }
    }
}

# Whitespace and code style only: analyzer code fixes (dotnet format analyzers) can change
# behavior, e.g. P/Invoke marshalling, so they are left to lint. Exit code 2 = changes needed.
# --report lists the files a pass changed (or would change). The style pass reports whitespace
# problems again as IDE0055, so count each file once. The passes run in turn: both write the
# same files, and each restores the project first.
$passes = 'whitespace', 'style'
$reportRoot = Join-Path ([IO.Path]::GetTempPath()) "wwan-probe-format-$([guid]::NewGuid())"
$format = Invoke-DotNetJob @(foreach ($pass in $passes) {
        , (@('format', $pass, $csproj, '--report', (Join-Path $reportRoot $pass)) + $(if ($Check) { '--verify-no-changes' } else { @() }))
    })
$powershellFiles = @(Invoke-WithBuiltInCommand {
        foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.ps1' -File -Recurse) {
            $source = Get-Content -LiteralPath $file.FullName -Raw
            if ([string]::IsNullOrEmpty($source)) { continue }
            # PSPlaceCloseBrace leaves a space where it breaks "... } }" and PSAvoidTrailingWhitespace
            # does not remove it, so strip trailing whitespace afterwards (also inside here-strings,
            # which have none today).
            $formatted = (Invoke-Formatter -ScriptDefinition $source -Settings $settings) -replace '(?m)[ \t]+(?=\r?$)', ''
            if ($source -ceq $formatted) { continue }
            if (-not $Check) { Set-Content -LiteralPath $file.FullName -Value $formatted -NoNewline -Encoding utf8NoBOM }
            $file.FullName
        }
    })
foreach ($result in Receive-Job $format -Wait -AutoRemoveJob) {
    if ($result.Output) { $result.Output | Out-Host }
    if ($result.ExitCode -ne 0 -and -not ($Check -and $result.ExitCode -eq 2)) { throw "dotnet format $($result.Name) failed (exit code $($result.ExitCode))." }
}
$csharpFiles = @(@(foreach ($pass in $passes) {
            (Get-Content -LiteralPath (Join-Path $reportRoot "$pass/format-report.json") -Raw | ConvertFrom-Json).FilePath
        }) | Sort-Object -Unique)
Remove-Item -LiteralPath $reportRoot -Recurse -Force

foreach ($path in $powershellFiles + $csharpFiles) {
    Write-Output "$(if ($Check) { 'Needs formatting' } else { 'Formatted' }): $(Get-RepoPath $path)"
}
$counts = "$($powershellFiles.Count) PowerShell file(s) and $($csharpFiles.Count) C# file(s)"
if ($powershellFiles.Count -eq 0 -and $csharpFiles.Count -eq 0) {
    Write-Output $(if ($Check) { 'Format check passed: no PowerShell or C# files need formatting.' } else { 'Nothing to format: all PowerShell and C# files are already formatted.' })
}
elseif ($Check) {
    throw "Format check failed: $counts need formatting. Run ./tool.ps1 format to fix them."
}
else {
    Write-Output "Formatted $counts."
}
