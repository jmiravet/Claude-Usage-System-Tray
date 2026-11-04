# Watchdog: starts the tray app and restarts it if it exits on an error.
# Stops when the user picks "Quit" (exit 0), another instance is running (exit 3),
# or the app fails 5 times in a row within a short time.
$dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$tray = Join-Path $dir 'ClaudeUsageTray.ps1'
$log  = Join-Path $dir 'tray.log'
$fails = 0
while ($true) {
    $start = Get-Date
    $p = Start-Process powershell.exe -WindowStyle Hidden -PassThru -Wait -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$tray`"")
    $code = $p.ExitCode
    if ($code -eq 0 -or $code -eq 3) { break }
    if (((Get-Date) - $start).TotalMinutes -gt 10) { $fails = 0 }
    $fails++
    try { Add-Content $log ('[{0:yyyy-MM-dd HH:mm:ss}] Watchdog: app exited with code {1}; restart {2}/5' -f (Get-Date), $code, $fails) } catch { }
    if ($fails -ge 5) { break }
    Start-Sleep -Seconds 10
}
