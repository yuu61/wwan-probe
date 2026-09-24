# Presentation: sequential (non-interactive) monitor loop for redirected stdin/stdout.

function Invoke-PlainMonitor($Session, [int]$Width = 100) {
    $view = @{ Paused = $false; Fetching = $false; Done = $false; Quit = $false; Unicode = $false }
    while ($true) {
        Invoke-MonitorSample $Session
        Show-PlainFrame (Get-MonitorFrame -Session $Session -View $view -Width $Width)
        if (Test-MonitorComplete $Session) { return }
        Start-Sleep -Seconds $Session.Config.Interval
    }
}
