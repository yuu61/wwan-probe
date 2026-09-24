# Presentation: writes frames to the console.

function Write-ConsoleLine {
    # TUI needs direct cursor-addressed console writes; Write-Output cannot do this.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string]$Text, [string]$Color, [int]$Width, [string]$BackgroundColor = '', [object[]]$Segments = @())

    [Console]::ForegroundColor = $Color
    if ($BackgroundColor) { [Console]::BackgroundColor = $BackgroundColor }
    if ($Segments.Count -gt 0) {
        $remaining = $Width
        foreach ($segment in $Segments) {
            if ($remaining -le 0) { break }
            $length = [math]::Min($segment.Text.Length, $remaining)
            [Console]::ForegroundColor = $segment.Color
            if ($null -ne $segment.GrayLevel) {
                $level = $segment.GrayLevel
                [Console]::Write("`e[38;2;$level;$level;${level}m")
            }
            [Console]::Write($segment.Text.Substring(0, $length))
            # End the RGB override before spaces, the NR suffix or the next line.
            if ($null -ne $segment.GrayLevel) { [Console]::Write("`e[39m") }
            $remaining -= $length
        }
        [Console]::ForegroundColor = $Color
        [Console]::Write(' ' * $remaining)
    }
    else {
        if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
        [Console]::Write($Text.PadRight($Width))
    }
    [Console]::ResetColor()
}

# Switches to/from the alternate screen buffer (VT). Leaving it restores the
# screen as it was before entering, so no TUI frame remains after exit.
function Set-AlternateScreen {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '')]
    param([bool]$Enabled)

    [Console]::Write($(if ($Enabled) { "`e[?1049h" } else { "`e[?1049l" }))
}

# Redraws the whole screen in place (no Clear-Host per frame to avoid flicker).
function Show-Frame($Frame, [int]$Width, [int]$Height) {
    $bodyRows = $Height - 1
    for ($row = 0; $row -lt $bodyRows; $row++) {
        [Console]::SetCursorPosition(0, $row)
        if ($row -lt $Frame.Body.Count) {
            $line = $Frame.Body[$row]
            Write-ConsoleLine -Text $line.Text -Color $line.Color -Width $Width -Segments $line.Segments
        }
        else {
            Write-ConsoleLine -Text '' -Color 'Gray' -Width $Width
        }
    }
    # Footer on the last row. Never write the bottom-right cell (it would scroll).
    [Console]::SetCursorPosition(0, $Height - 1)
    Write-ConsoleLine -Text $Frame.Footer.Text -Color $Frame.Footer.Color -Width $Width -BackgroundColor 'DarkCyan'
}

# Plain sequential output for redirected consoles (pipes, logs, CI).
function Show-PlainFrame($Frame) {
    foreach ($line in $Frame.Body) { [Console]::Out.WriteLine($line.Text) }
    [Console]::Out.WriteLine('')
}
