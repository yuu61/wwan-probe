# Presentation: writes frames to the console.

function Write-ConsoleLine {
    # TUI needs direct cursor-addressed console writes; Write-Output cannot do this.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '')]
    param([string]$Text, [string]$Color, [int]$Width, [string]$BackgroundColor = "")

    if ($Text.Length -gt $Width) { $Text = $Text.Substring(0, $Width) }
    [Console]::ForegroundColor = $Color
    if ($BackgroundColor) { [Console]::BackgroundColor = $BackgroundColor }
    [Console]::Write($Text.PadRight($Width))
    [Console]::ResetColor()
}

# Redraws the whole screen in place (no Clear-Host per frame to avoid flicker).
function Show-Frame($Frame, [int]$Width, [int]$Height) {
    $bodyRows = $Height - 1
    for ($row = 0; $row -lt $bodyRows; $row++) {
        [Console]::SetCursorPosition(0, $row)
        if ($row -lt $Frame.Body.Count) {
            $line = $Frame.Body[$row]
            Write-ConsoleLine -Text $line.Text -Color $line.Color -Width $Width
        }
        else {
            Write-ConsoleLine -Text "" -Color "Gray" -Width $Width
        }
    }
    # Footer on the last row. Never write the bottom-right cell (it would scroll).
    [Console]::SetCursorPosition(0, $Height - 1)
    Write-ConsoleLine -Text $Frame.Footer.Text -Color $Frame.Footer.Color -Width $Width -BackgroundColor "DarkCyan"
}

# Plain sequential output for redirected consoles (pipes, logs, CI).
function Show-PlainFrame($Frame) {
    foreach ($line in $Frame.Body) { [Console]::Out.WriteLine($line.Text) }
    [Console]::Out.WriteLine("")
}
