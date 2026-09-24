# Presentation: interactive full-screen TUI loop.
# Keys: q / Esc / Ctrl+C = quit, p = pause/resume, r = refresh now, R = reset statistics,
#       1-6 = show/hide one history chart, g = show/hide all charts,
#       h = handover history, s = satellite list (-Nmea),
#       Up / Down = chart height, newer / older handovers or scroll satellites

# Renders current state; clears the screen once when the window is resized.
function Show-TuiScreen($Session, [hashtable]$View) {
    $w = [Console]::WindowWidth - 1
    $h = [Console]::WindowHeight
    if ($w -ne $View.LastWidth -or $h -ne $View.LastHeight) {
        [Console]::Clear()
        $View.LastWidth = $w; $View.LastHeight = $h
    }
    $frame = Get-MonitorFrame -Session $Session -View $View -Width $w
    Show-Frame -Frame $frame -Width $w -Height $h
}

function Test-WindowResized([hashtable]$View) {
    return ([Console]::WindowWidth - 1 -ne $View.LastWidth -or [Console]::WindowHeight -ne $View.LastHeight)
}

function Read-TuiKey {
    if ([Console]::KeyAvailable) { return [Console]::ReadKey($true) }
}

# Drain queued keys on every tick, including during sampling. Coalesce key repeats
# into one redraw so holding an arrow does not build up a queue of full frames.
function Read-TuiInput([hashtable]$View) {
    while ($null -ne ($key = Read-TuiKey)) {
        $isCtrlC = ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))
        if ($isCtrlC -or $key.Key -eq 'Q' -or $key.Key -eq 'Escape') { $View.Quit = $true; return }
        if ($key.Key -eq 'P') {
            $View.Paused = -not $View.Paused
            $View.Dirty = $true
            if (-not $View.Paused -and -not $View.Fetching) { $View.RefreshRequested = $true }
        }
        # Uppercase R (by character, so Caps Lock counts) resets; lowercase r refreshes.
        if ($key.KeyChar -ceq 'R') { $View.ResetRequested = $true; continue }
        # An in-flight sample already satisfies a refresh request.
        if ($key.Key -eq 'R' -and -not $View.Fetching) { $View.RefreshRequested = $true }
        if ($key.Key -eq 'H') {
            $View.HandoverVisible = -not $View.HandoverVisible
            $View.HandoverOffset = 0
            $View.SatelliteVisible = $false
            $View.Dirty = $true
            continue
        }
        if ($key.Key -eq 'S') {
            $View.SatelliteVisible = -not $View.SatelliteVisible
            $View.SatelliteOffset = 0
            $View.HandoverVisible = $false
            $View.Dirty = $true
            continue
        }
        if ($key.Key -eq 'UpArrow' -or $key.Key -eq 'DownArrow') {
            if ($View.SatelliteVisible) {
                $delta = if ($key.Key -eq 'UpArrow') { -1 } else { 1 }
                $View.SatelliteOffset = [math]::Max(0, [int]$View.SatelliteOffset + $delta)
                $View.Dirty = $true
                continue
            }
            if ($View.HandoverVisible) {
                $delta = if ($key.Key -eq 'UpArrow') { -1 } else { 1 }
                $View.HandoverOffset = [math]::Max(0, [int]$View.HandoverOffset + $delta)
                $View.Dirty = $true
                continue
            }
            $rows = Step-ChartHeight $View.ChartRows $(if ($key.Key -eq 'UpArrow') { 1 } else { -1 })
            if ($rows -ne $View.ChartRows) { $View.ChartRows = $rows; $View.Dirty = $true }
            continue
        }
        $chartKey = if ($key.Key -eq 'G') { 'all' } else { "$($key.KeyChar)" }
        if (Switch-ChartVisibility $View.ChartVisible $chartKey) { $View.Dirty = $true }
    }
}

# Input and rendering run independently of the single background sample.
function Invoke-TuiLoop($Session, [hashtable]$View, $Sampler) {
    $nextSample = [datetime]::MinValue
    while (-not $view.Quit) {
        Read-TuiInput $view
        if ($view.Quit) { break }
        # A sample still in flight is committed afterwards and counts toward the new statistics.
        if ($view.ResetRequested) {
            Reset-MonitorStatistic $Session
            $view.ResetRequested = $false
            $view.HandoverOffset = 0
            $view.Dirty = $true
        }

        if ($view.Fetching -and $sampler.Pending.IsCompleted) {
            Add-MonitorSnapshot $Session (Receive-MonitorSample $sampler)
            $view.Fetching = $false
            $view.Done = Test-MonitorComplete $Session
            $view.Dirty = $true
            $nextSample = (Get-Date).AddSeconds($Session.Config.Interval)
        }
        if (-not $view.Done -and -not $view.Fetching -and
            ($view.RefreshRequested -or (-not $view.Paused -and (Get-Date) -ge $nextSample))) {
            $view.RefreshRequested = $false
            Start-MonitorSample $sampler $Session.Modem $Session.Summary.At $Session.GpsReceiver $Session.NmeaReceiver
            $view.Fetching = $true
            $view.Dirty = $true
        }
        if ($view.Dirty -or (Test-WindowResized $view)) {
            Show-TuiScreen $Session $view
            $view.Dirty = $false
        }
        if ($view.Done) { break }
        Start-Sleep -Milliseconds 25
    }
}

function Invoke-TuiMonitor($Session) {
    $view = @{
        Paused = $false; Fetching = $false; Done = $false; Quit = $false; Unicode = $true
        RefreshRequested = $true; ResetRequested = $false; LastWidth = 0; LastHeight = 0; ChartVisible = New-ChartVisibility
        ChartRows = $script:ChartRowsDefault; Dirty = $true
        HandoverVisible = $false; HandoverOffset = 0; SatelliteVisible = $false; SatelliteOffset = 0
    }
    $savedCursor = [Console]::CursorVisible
    $savedCtrlC = [Console]::TreatControlCAsInput
    $savedEncoding = [Console]::OutputEncoding
    $inAltScreen = $false
    $sampler = $null

    try {
        $sampler = New-MonitorSampler
        # Block glyphs (U+2581..U+2588) become '?' under the default CP932 output encoding.
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        # Draw on the alternate screen so quitting restores the shell's previous screen.
        Set-AlternateScreen $true
        $inAltScreen = $true
        [Console]::CursorVisible = $false
        [Console]::TreatControlCAsInput = $true
        [Console]::Clear()

        Invoke-TuiLoop -Session $Session -View $view -Sampler $sampler
    }
    finally {
        try {
            [Console]::ResetColor()
            if ($inAltScreen) { Set-AlternateScreen $false }
            [Console]::TreatControlCAsInput = $savedCtrlC
            [Console]::CursorVisible = $savedCursor
            [Console]::OutputEncoding = $savedEncoding
        }
        finally { Remove-MonitorSampler $sampler }
    }
}
