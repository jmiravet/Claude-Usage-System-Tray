# Installs Claude Usage System Tray: adds a Startup shortcut and launches the app now.
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$vbs = Join-Path $dir 'Start.vbs'
$lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Claude Usage.lnk'
$sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$sc.TargetPath = 'wscript.exe'
$sc.Arguments = '"' + $vbs + '"'
$sc.WorkingDirectory = $dir
$sc.Description = 'Claude usage in the system tray'
$sc.Save()
Write-Host "Startup shortcut: $lnk"
Start-Process wscript.exe -ArgumentList ('"' + $vbs + '"')
Write-Host 'Claude Usage System Tray started.'
