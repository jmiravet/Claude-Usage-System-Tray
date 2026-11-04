# Claude Usage System Tray

> Windows tray icon showing your Claude usage limits as a filling ring, with a details panel. Based on [apexlocal-jz/claude-usage-tray](https://github.com/apexlocal-jz/claude-usage-tray).

Icono en la bandeja de Windows que muestra el uso de tus límites de Claude: el asterisco de Claude con un anillo que se rellena en sentido horario según el uso de la sesión de 5 horas (verde < 70 %, ámbar < 90 %, rojo a partir de 90 %; gris si los datos tienen más de 20 min).

Al hacer clic se abre un panel junto al icono con la sesión, el límite semanal, cuándo se reinicia cada uno y el desglose semanal por producto. Sigue el tema claro/oscuro de Windows y se coloca bien con barras de tareas verticales.

Basado en [apexlocal-jz/claude-usage-tray](https://github.com/apexlocal-jz/claude-usage-tray) de Joe Zeng. Esta versión rehace el icono y el panel, añade un vigilante que la reabre si se cae y está en español.

> Herramienta no oficial, sin relación con Anthropic. Usa un endpoint no documentado (`/api/oauth/usage`) que puede cambiar.

## Requisitos

- Windows 10/11 con Windows PowerShell 5.1 (incluido en Windows)
- Claude Code instalado y con la sesión iniciada (`~/.claude/.credentials.json`)

## Instalación

1. Descarga el repositorio (Code → Download ZIP) y descomprímelo en una carpeta fija, por ejemplo `C:\Users\<tú>\.claude\usage-tray`.
2. En PowerShell:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\<tú>\.claude\usage-tray\Install.ps1"
   ```

Esto crea un acceso directo en la carpeta de Inicio de Windows y abre la app. Para quitarla, ejecuta `Uninstall.ps1` igual.

## Privacidad y red

- Lee el token OAuth que mantiene Claude Code; **no** lo renueva ni lo escribe. Si caduca, el aviso pide abrir Claude Code.
- Solo consulta `GET https://api.anthropic.com/api/oauth/usage` cada ~5 min. Sin telemetría.
- Guarda `tray.log` y `last-usage.json` (últimos porcentajes) en su propia carpeta.

## Archivos

| Archivo | Qué hace |
|---|---|
| `ClaudeUsageTray.ps1` | La app (icono, panel, consultas) |
| `Watchdog.ps1` | La reabre si termina por un fallo; se detiene si eliges *Salir* |
| `Start.vbs` | Lanza el vigilante sin ventana visible |
| `Install.ps1` / `Uninstall.ps1` | Inicio automático e instalación/desinstalación |
| `tests/Preview.ps1` | Genera `panel.png` e `icons.png` para revisar el diseño sin tocar la bandeja |

## Licencia

MIT. Ver [LICENSE](LICENSE).
