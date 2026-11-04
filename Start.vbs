' Abre el vigilante de Claude Usage sin ninguna ventana visible.
Dim sh, dir
Set sh = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\Watchdog.ps1""", 0, False
