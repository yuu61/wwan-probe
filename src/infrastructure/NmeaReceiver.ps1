# Infrastructure: satellites from the GNSS driver's NMEA stream (lte_monitor.ps1 -Nmea).
# The driver requires an administrator, so a hidden helper process (NmeaHelper.ps1) runs
# elevated (UAC when the monitor is not) and publishes a state file about once a second.
# A non-elevated monitor cannot terminate the helper: it asks the helper to stop through a
# stop file, and the helper also exits when the monitor process ends.
#
# State file (JSON, written by the helper, no coordinates):
#   @{ Status = 'Starting' | 'Receiving' | 'Error'; Error; UpdatedUnixMs (heartbeat);
#      NmeaUnixMs (last valid sentence, $null = none yet); Satellites; UsedCount }

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Writes the whole state to a temporary file and replaces the previous one, so a reader
# never sees a partial file. The replace fails while the monitor is reading the file (even
# with FileShare.Delete); then it returns $false and the caller retries on its next cycle.
function Write-NmeaState([string]$Path, $State) {
    $temporary = "$Path.tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 5 -Compress))
        [IO.File]::Move($temporary, $Path, $true)
        return $true
    }
    catch [IO.IOException], [UnauthorizedAccessException] { return $false }
}

# Latest state, or $null when none has been published or it cannot be read yet.
function Read-NmeaState([string]$Path) {
    try { return [IO.File]::ReadAllText($Path) | ConvertFrom-Json }
    catch { return $null }
}

function Start-NmeaReceiver {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param()

    $receiver = [pscustomobject]@{ Process = $null; StateDir = $null; Error = $null }
    try {
        $receiver.StateDir = Join-Path ([IO.Path]::GetTempPath()) "wwan-nmea-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $receiver.StateDir
        $self = [Diagnostics.Process]::GetCurrentProcess()
        # Paths are quoted PowerShell literals inside an encoded command, so spaces and
        # apostrophes survive and nothing from the state directory is executed.
        $quote = { param($Text) "'" + $Text.Replace("'", "''") + "'" }
        $command = '& {0} -StateDir {1} -ParentId {2} -ParentStartTicks {3}' -f (& $quote (Join-Path $PSScriptRoot 'NmeaHelper.ps1')),
        (& $quote $receiver.StateDir), $self.Id, $self.StartTime.ToUniversalTime().Ticks
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
        $start = @{
            FilePath     = Join-Path $PSHOME 'pwsh.exe'
            ArgumentList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', "$(Get-ExecutionPolicy)", '-EncodedCommand', $encoded)
            WindowStyle  = 'Hidden'
            PassThru     = $true
        }
        # Blocks until UAC is answered; a declined prompt throws and leaves the monitor running.
        if (-not (Test-Administrator)) { $start.Verb = 'RunAs' }
        $receiver.Process = Start-Process @start
    }
    catch { $receiver.Error = "NMEA helper not started: $($_.Exception.Message)" }
    return $receiver
}

# Asks the helper to stop (it restores the driver's NMEA logging) and waits at most
# $TimeoutMs: the driver decides how long a pending NMEA read takes to cancel.
function Stop-NmeaReceiver {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param($Receiver, [int]$TimeoutMs = 5000)

    if ($null -eq $Receiver -or $null -eq $Receiver.StateDir) { return }
    $exited = $true
    if ($null -ne $Receiver.Process) {
        $null = New-Item -ItemType File -Path (Join-Path $Receiver.StateDir 'stop') -Force -ErrorAction SilentlyContinue
        # If the handle of an elevated helper cannot be queried, it still sees the stop file.
        try { $exited = $Receiver.Process.HasExited -or $Receiver.Process.WaitForExit($TimeoutMs) }
        catch { $exited = $false }
    }
    # A helper still running removes the directory itself once it sees this process exit.
    if ($exited) { Remove-Item -LiteralPath $Receiver.StateDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# Pure conversion of the helper state for display and tests.
#   Status: Starting | Receiving | Stale (heartbeat older than 10 s) | Unavailable (Error)
#   InView = distinct satellites, Used = distinct satellites in the fix,
#   Systems = ordered @{ <system> = @{ InView; Used } } in display order.
function ConvertFrom-NmeaState {
    param($State, [string]$ReceiverError, [bool]$HelperExited, $ExitCode, [DateTimeOffset]$Now = [DateTimeOffset]::UtcNow)

    $observation = [pscustomobject]@{
        Status = 'Starting'; Error = $null; UpdatedUtc = $null; NmeaReceived = $false
        Satellites = @(); InView = 0; Used = 0; Systems = [ordered]@{}
    }
    if ($ReceiverError) { $observation.Status = 'Unavailable'; $observation.Error = $ReceiverError; return $observation }
    if ($State.Status -eq 'Error') { $observation.Status = 'Unavailable'; $observation.Error = $State.Error; return $observation }
    if ($HelperExited) {
        $observation.Status = 'Unavailable'
        $observation.Error = "NMEA helper exited (code $(if ($null -ne $ExitCode) { $ExitCode } else { '?' })) without a report"
        return $observation
    }
    if ($null -eq $State) { return $observation }
    $updated = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$State.UpdatedUnixMs)
    $observation.UpdatedUtc = $updated.ToString('o')
    if (($Now - $updated).TotalSeconds -gt 10) { $observation.Status = 'Stale'; return $observation }
    if ($State.Status -ne 'Receiving') { return $observation }
    $observation.Status = 'Receiving'
    $observation.NmeaReceived = $null -ne $State.NmeaUnixMs
    $observation.Satellites = @($State.Satellites)
    $observation.Used = [int]$State.UsedCount
    $observation.InView = @($observation.Satellites | ForEach-Object { "$($_.System):$($_.Id)" } | Select-Object -Unique).Count
    foreach ($system in $script:NmeaSystems) {
        $members = @($observation.Satellites | Where-Object System -EQ $system)
        if ($members.Count -eq 0) { continue }
        $observation.Systems[$system] = [pscustomobject]@{
            InView = @($members.Id | Select-Object -Unique).Count
            Used   = @($members | Where-Object Used | ForEach-Object Id | Select-Object -Unique).Count
        }
    }
    return $observation
}

function Get-NmeaObservation($Receiver) {
    if ($null -eq $Receiver) { return $null }
    if ($Receiver.Error) { return ConvertFrom-NmeaState $null -ReceiverError $Receiver.Error }
    # Satellite failures must never fail the LTE sample that carries them.
    try {
        $state = Read-NmeaState (Join-Path $Receiver.StateDir 'state.json')
        $exited = $Receiver.Process.HasExited
        $exitCode = $null
        if ($exited) { try { $exitCode = $Receiver.Process.ExitCode } catch { $exitCode = $null } }
        return ConvertFrom-NmeaState $state -HelperExited $exited -ExitCode $exitCode
    }
    catch { return ConvertFrom-NmeaState $null -ReceiverError "NMEA helper status unavailable: $($_.Exception.Message)" }
}
