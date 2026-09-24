# Presentation: interactive full-screen TUI loop.
# Keys: q / Esc / Ctrl+C = quit, p = pause/resume, r = refresh now

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

# Waits for the interval (or indefinitely while paused), polling keys in 100ms slices.
# Returns when the interval elapses, on resume, on refresh request, or on quit.
# Keys are always drained at least once per call, so Interval=0 stays responsive.
function Wait-TuiInput($Session, [hashtable]$View) {
    $deadline = (Get-Date).AddSeconds($Session.Config.Interval)
    while ($true) {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            $isCtrlC = ($key.Key -eq 'C' -and ($key.Modifiers -band [ConsoleModifiers]::Control))
            if ($isCtrlC -or $key.Key -eq 'Q' -or $key.Key -eq 'Escape') { $View.Quit = $true; return }
            if ($key.Key -eq 'P') {
                $View.Paused = -not $View.Paused
                Show-TuiScreen $Session $View
                if (-not $View.Paused) { return }
            }
            if ($key.Key -eq 'R') { $View.RefreshRequested = $true; return }
        }
        # Keep layout correct while waiting if the window is resized.
        if (Test-WindowResized $View) { Show-TuiScreen $Session $View }
        if ((Get-Date) -ge $deadline -and -not $View.Paused) { return }
        Start-Sleep -Milliseconds 100
    }
}

function Invoke-TuiMonitor($Session) {
    $view = @{
        Paused = $false; Fetching = $false; Done = $false; Quit = $false
        RefreshRequested = $true; LastWidth = 0; LastHeight = 0
    }
    $savedCursor = [Console]::CursorVisible
    $savedCtrlC = [Console]::TreatControlCAsInput

    try {
        [Console]::CursorVisible = $false
        [Console]::TreatControlCAsInput = $true
        [Console]::Clear()

        while (-not $view.Quit) {
            if (-not $view.Paused -or $view.RefreshRequested) {
                $view.RefreshRequested = $false
                $view.Fetching = $true
                Show-TuiScreen $Session $view
                Invoke-MonitorSample $Session
                $view.Fetching = $false
            }
            if (Test-MonitorComplete $Session) { $view.Done = $true }
            Show-TuiScreen $Session $view
            if ($view.Done) { break }

            Wait-TuiInput $Session $view
        }
    }
    finally {
        [Console]::ResetColor()
        [Console]::TreatControlCAsInput = $savedCtrlC
        [Console]::CursorVisible = $savedCursor
        # Keep the last frame on screen; the message replaces the footer row.
        if ($view.LastHeight -gt 0) { [Console]::SetCursorPosition(0, $view.LastHeight - 1) }
    }
}
