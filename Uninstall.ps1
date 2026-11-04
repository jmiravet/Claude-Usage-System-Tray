# Desinstala Claude Usage: quita el inicio automatico, cierra la app y borra su carpeta.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage.lnk'
if (Test-Path $lnk) { Remove-Item $lnk -Force }
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$dir\Watchdog.ps1*" -or $_.CommandLine -like "*$dir\ClaudeUsageTray.ps1*" } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction Stop } catch { } }
Start-Sleep -Milliseconds 500
Set-Location $env:TEMP
Remove-Item $dir -Recurse -Force
Write-Host 'Claude Usage desinstalado.'
