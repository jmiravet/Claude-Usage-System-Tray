# Instala Claude Usage: crea el acceso directo de inicio automatico y lo abre ahora.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $dir 'Start.vbs'
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage.lnk'
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $dir
$sc.Description = 'Uso de Claude en la bandeja del sistema'
$sc.Save()
Write-Host "Inicio automatico: $lnk"
Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')
Write-Host 'Claude Usage iniciado.'
