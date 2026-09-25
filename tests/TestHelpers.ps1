# Shared setup for tests/*.Tests.ps1 (not a test itself): dot-source it first, at the test's script
# scope. It loads every src/ definition (src/Load.ps1) and the assertions below; stubs a test
# defines afterwards replace the production functions of the same name.

. (Join-Path (Split-Path $PSScriptRoot -Parent) 'src/Load.ps1')

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
