# Vigilante: abre la app de bandeja y la vuelve a abrir si se cierra por un fallo.
# Se detiene si el usuario elige "Salir" (codigo 0), si ya hay otra instancia
# (codigo 3) o si falla 5 veces seguidas en poco tiempo.
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
    try { Add-Content $log ('[{0:yyyy-MM-dd HH:mm:ss}] Vigilante: la app termino con codigo {1}; reinicio {2}/5' -f (Get-Date), $code, $fails) } catch { }
    if ($fails -ge 5) { break }
    Start-Sleep -Seconds 10
}
