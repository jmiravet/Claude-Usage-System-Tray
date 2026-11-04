#requires -version 5.1
# Claude Usage System Tray: uso de los limites de Claude en la bandeja de Windows.
# Lee el token de Claude Code (~/.claude/.credentials.json) y solo consulta api.anthropic.com.
# Codigos de salida (los usa Watchdog.ps1): 0 = Salir, 3 = ya habia otra instancia, otro = fallo.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$LogFile   = Join-Path $PSScriptRoot 'tray.log'
$CacheFile = Join-Path $PSScriptRoot 'last-usage.json'
$CredFile  = Join-Path $env:USERPROFILE '.claude\.credentials.json'

function Write-Log([string]$msg) {
    try {
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 256KB) {
            Move-Item $LogFile "$LogFile.old" -Force
        }
        Add-Content -Path $LogFile -Value ('[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date), $msg) -Encoding UTF8
    } catch { }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class TrayNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
}
'@

[void][TrayNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()
# Cualquier excepcion en un evento de la interfaz se registra en vez de cerrar la app.
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-Log ('Excepcion de interfaz (ignorada): ' + $e.Exception.Message)
})

$UsageUrl     = 'https://api.anthropic.com/api/oauth/usage'
$PollSec      = 300
$JitterSec    = 45
$TimeoutMs    = 8000
$MaxBodyBytes = 1MB
$StaleMin     = 20       # datos mas viejos que esto: icono gris
$Es           = [Globalization.CultureInfo]::GetCultureInfo('es-ES')

$script:nextFetch   = Get-Date
$script:backoff429  = [DateTime]::MinValue
$script:panelClosed = [DateTime]::MinValue
$script:fonts       = @{}
$script:hit         = @()
$script:rand        = New-Object Random

function Invoke-Safe([string]$name, [scriptblock]$sb) {
    try { & $sb } catch { Write-Log ("Error en {0}: {1}" -f $name, $_.Exception.Message) }
}

# ---------- Cache (para mostrar los ultimos datos al arrancar) ----------
function Save-Cache([string]$body) {
    try {
        $obj = @{ fetchedAt = (Get-Date).ToString('o'); body = $body }
        Set-Content -Path $CacheFile -Value ($obj | ConvertTo-Json -Compress) -Encoding UTF8
    } catch { Write-Log "No se pudo guardar la cache: $($_.Exception.Message)" }
}

function Read-Cache {
    if (-not (Test-Path $CacheFile)) { return }
    try {
        $c = Get-Content $CacheFile -Raw | ConvertFrom-Json
        $script:data = $c.body | ConvertFrom-Json
        $script:fetchedAt = [DateTime]::Parse($c.fetchedAt, $null, [Globalization.DateTimeStyles]::RoundtripKind).ToLocalTime()
    } catch { Write-Log 'Cache ilegible; se ignora' }
}

# ---------- Interpretacion de la respuesta ----------
function ConvertTo-LocalDate($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [DateTime]) { return $v.ToLocalTime() }
    try { return [DateTimeOffset]::Parse([string]$v, [Globalization.CultureInfo]::InvariantCulture).LocalDateTime } catch { return $null }
}

function Get-Limits {
    $out = New-Object System.Collections.ArrayList
    $j = $script:data
    if (-not $j) { return ,$out }
    if ($j.limits) {
        foreach ($l in @($j.limits)) {
            if ($null -eq $l.percent) { continue }
            $kind = [string]$l.kind
            if ($kind -eq 'session') { $name = 'Sesión (5 horas)' }
            elseif ($kind -eq 'weekly_all') { $name = 'Semanal · todos los modelos' }
            elseif ($kind -like 'weekly_*') { $name = 'Semanal · ' + $Es.TextInfo.ToTitleCase($kind.Substring(7).Replace('_', ' ')) }
            else { $name = $kind }
            [void]$out.Add(@{ Name = $name; Pct = [double]$l.percent; Reset = (ConvertTo-LocalDate $l.resets_at); Group = [string]$l.group })
        }
    }
    if ($out.Count -eq 0) {
        # Campos antiguos de la API, por si desaparece "limits"
        foreach ($p in @(
            @('five_hour', 'Sesión (5 horas)', 'session'),
            @('seven_day', 'Semanal · todos los modelos', 'weekly'))) {
            $n = $j.($p[0])
            if ($n -and $null -ne $n.utilization) {
                [void]$out.Add(@{ Name = $p[1]; Pct = [double]$n.utilization; Reset = (ConvertTo-LocalDate $n.resets_at); Group = $p[2] })
            }
        }
    }
    return ,$out
}

function Get-Limit([string]$group) {
    foreach ($l in (Get-Limits)) { if ($l.Group -eq $group) { return $l } }
}

function Get-Breakdown {
    $rows = @()
    if ($script:data -and $script:data.seven_day_breakdown -and $script:data.seven_day_breakdown.rows) {
        foreach ($r in @($script:data.seven_day_breakdown.rows)) {
            if ($r.percent -and [double]$r.percent -gt 0) { $rows += ('{0} {1}%' -f $r.display_name, [int]$r.percent) }
        }
    }
    return $rows
}

# ---------- Red ----------
function Get-Credential {
    if (-not (Test-Path $CredFile)) { return $null }
    try {
        $o = (Get-Content $CredFile -Raw | ConvertFrom-Json).claudeAiOauth
        if ([string]::IsNullOrWhiteSpace($o.accessToken)) { return $null }
        $exp = $null
        if ($o.expiresAt) {
            $n = [double]$o.expiresAt
            if ($n -gt 1e12) { $exp = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$n).UtcDateTime }
            elseif ($n -gt 0) { $exp = [DateTimeOffset]::FromUnixTimeSeconds([int64]$n).UtcDateTime }
        }
        return @{ Token = $o.accessToken; ExpiresUtc = $exp }
    } catch {
        # Claude Code puede estar reescribiendo el archivo; se reintenta luego.
        Write-Log ('No se pudo leer el archivo de credenciales ({0})' -f $_.Exception.GetType().Name)
        return $null
    }
}

function Invoke-Fetch {
    $now = Get-Date
    $script:nextFetch = $now.AddSeconds($PollSec + $script:rand.Next(0, $JitterSec))
    if ($now -lt $script:backoff429) { return }

    $cred = Get-Credential
    if (-not $cred) {
        $script:status = 'No encuentro las credenciales de Claude Code'
        $script:nextFetch = $now.AddSeconds(60)
        return
    }
    if ($cred.ExpiresUtc -and [DateTime]::UtcNow -ge $cred.ExpiresUtc.AddSeconds(-60)) {
        # Este programa no renueva tokens: eso lo hace Claude Code al abrirlo.
        $script:status = 'Sesión caducada: abre Claude Code'
        $script:nextFetch = $now.AddSeconds(60)
        return
    }

    $req = [System.Net.HttpWebRequest]::Create($UsageUrl)
    $req.Timeout = $TimeoutMs
    $req.ReadWriteTimeout = $TimeoutMs
    $req.Accept = 'application/json'
    $req.UserAgent = 'claude-usage-system-tray/1.0'
    $req.Headers.Add('Authorization', "Bearer $($cred.Token)")
    $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
    try {
        $resp = $req.GetResponse()
        try {
            $stream = $resp.GetResponseStream()
            $ms = New-Object System.IO.MemoryStream
            $buf = New-Object byte[] 8192
            while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                if ($ms.Length + $n -gt $MaxBodyBytes) { throw 'Respuesta demasiado grande' }
                $ms.Write($buf, 0, $n)
            }
            $body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
            $ms.Dispose()
        } finally { $resp.Dispose() }
        $script:data = $body | ConvertFrom-Json
        $script:fetchedAt = Get-Date
        $script:status = $null
        Save-Cache $body
    } catch [System.Net.WebException] {
        $r = $_.Exception.Response -as [System.Net.HttpWebResponse]
        $code = if ($r) { [int]$r.StatusCode } else { 0 }
        if ($code -eq 429) {
            $retry = 600
            $h = $r.Headers['Retry-After']
            $tmp = 0
            if ($h -and [int]::TryParse($h, [ref]$tmp) -and $tmp -gt 0) { $retry = [math]::Min($tmp, 3600) }
            $script:backoff429 = $now.AddSeconds($retry + 30)
            $script:nextFetch = $script:backoff429
            $script:status = 'Demasiadas consultas; reintento en {0} min' -f [math]::Ceiling(($retry + 30) / 60)
        } elseif ($code -eq 401) {
            $script:status = 'Token rechazado: abre Claude Code'
        } else {
            $script:status = 'Sin conexión con Anthropic'
            $script:nextFetch = $now.AddSeconds(90)
        }
        Write-Log ('Fallo de red ({0}): {1}' -f $code, $_.Exception.Message)
        if ($r) { $r.Dispose() }
    } catch {
        $script:status = 'Error al leer el uso'
        Write-Log ('Fallo al consultar: ' + $_.Exception.Message)
    }
}

# ---------- Colores ----------
function Get-PctColor([double]$pct) {
    if ($pct -ge 90) { return [System.Drawing.Color]::FromArgb(224, 72, 72) }
    if ($pct -ge 70) { return [System.Drawing.Color]::FromArgb(232, 156, 32) }
    return [System.Drawing.Color]::FromArgb(46, 164, 92)
}

function Get-Palette {
    $light = $false
    try { $light = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme).AppsUseLightTheme -eq 1 } catch { }
    $c = { param($r, $g, $b) [System.Drawing.Color]::FromArgb($r, $g, $b) }
    if ($light) {
        return @{ Bg = (& $c 249 249 249); Fg = (& $c 26 26 26); Sub = (& $c 96 96 96); Track = (& $c 224 224 224); Line = (& $c 226 226 226); Accent = (& $c 0 103 192); Warn = (& $c 176 106 0) }
    }
    return @{ Bg = (& $c 36 36 36); Fg = (& $c 242 242 242); Sub = (& $c 164 164 164); Track = (& $c 64 64 64); Line = (& $c 58 58 58); Accent = (& $c 110 172 255); Warn = (& $c 244 186 72) }
}

function New-RoundedPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$r) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = [single]([math]::Max(1, [math]::Min($r * 2, [math]::Min($w, $h))))
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

# ---------- Icono de la bandeja ----------
# Asterisco naranja de Claude en el centro y un anillo que se rellena en sentido
# horario desde arriba segun el % de la sesion. $state: ok | stale | error | loading.
# Se dibuja a 4x y se reduce para que quede nitido a 16-32 px.
$ClaudeOrange = [System.Drawing.Color]::FromArgb(217, 119, 87)
function New-IconBitmap([int]$sz, [double]$pct, [string]$state) {
    $k = 4; $big = $sz * $k
    $hi = New-Object System.Drawing.Bitmap $big, $big
    $g = [System.Drawing.Graphics]::FromImage($hi)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $ringW = [single]($big * 0.125)
    $r = [single](($big - $ringW) / 2 - $k * 0.25)
    $c = [single]($big / 2)
    $rect = New-Object System.Drawing.RectangleF ($c - $r), ($c - $r), (2 * $r), (2 * $r)

    # Pista del anillo (gris semitransparente: se ve en barra clara y oscura)
    $track = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 140, 140, 140)), $ringW
    $g.DrawEllipse($track, $rect); $track.Dispose()

    # Relleno horario desde las 12
    if (($state -eq 'ok' -or $state -eq 'stale') -and $pct -gt 0) {
        $col = if ($state -eq 'stale') { [System.Drawing.Color]::FromArgb(150, 150, 150) } else { Get-PctColor $pct }
        $pen = New-Object System.Drawing.Pen $col, $ringW
        $sweep = [single](360 * [math]::Min(100, $pct) / 100)
        if ($sweep -ge 359.5) { $g.DrawEllipse($pen, $rect) }
        else {
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $g.DrawArc($pen, $rect, -90, [math]::Max($sweep, 4))
        }
        $pen.Dispose()
    }

    # Asterisco de Claude: rayos finos de longitud ligeramente irregular
    $starCol = if ($state -eq 'error') { [System.Drawing.Color]::FromArgb(150, 150, 150) } else { $ClaudeOrange }
    $starR = [single]($r - $ringW / 2 - $big * 0.085)
    $sp = New-Object System.Drawing.Pen $starCol, ([single]($big * 0.07))
    $sp.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $sp.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $lens = @(1.0, 0.78, 0.96, 0.82, 1.0, 0.76, 0.94, 0.84)
    for ($i = 0; $i -lt $lens.Count; $i++) {
        $a = ($i * 45 + 10) * [math]::PI / 180
        $len = $starR * $lens[$i]
        $g.DrawLine($sp, $c, $c, [single]($c + $len * [math]::Cos($a)), [single]($c + $len * [math]::Sin($a)))
    }
    $sp.Dispose(); $g.Dispose()

    $bmp = New-Object System.Drawing.Bitmap $sz, $sz
    $g2 = [System.Drawing.Graphics]::FromImage($bmp)
    $g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g2.Clear([System.Drawing.Color]::Transparent)
    $g2.DrawImage($hi, 0, 0, $sz, $sz)
    $g2.Dispose(); $hi.Dispose()
    return $bmp
}

function New-TrayIcon([double]$pct, [string]$state) {
    $sz = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
    if ($sz -lt 16) { $sz = 16 }
    $bmp = New-IconBitmap $sz $pct $state
    $h = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
    [void][TrayNative]::DestroyIcon($h)
    $bmp.Dispose()
    return $icon
}

function Get-IsStale {
    return (-not $script:fetchedAt) -or (((Get-Date) - $script:fetchedAt).TotalMinutes -gt $StaleMin)
}

function Update-Tray {
    $sess = Get-Limit 'session'
    $week = Get-Limit 'weekly'
    if ($sess) {
        $pct = [int][math]::Round($sess.Pct)
        $state = if (Get-IsStale) { 'stale' } else { 'ok' }
        $icon = New-TrayIcon $sess.Pct $state
        $tip = 'Claude · sesión {0}%' -f $pct
        if ($week) { $tip += ' · semana {0}%' -f [int][math]::Round($week.Pct) }
    } elseif ($script:status) {
        $icon = New-TrayIcon 0 'error'
        $tip = 'Claude'
    } else {
        $icon = New-TrayIcon 0 'loading'
        $tip = 'Claude · cargando uso'
    }
    if ($script:status) { $tip += "`n" + $script:status }
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 62) + '…' }

    $old = $script:currentIcon
    $script:tray.Icon = $icon
    $script:tray.Text = $tip
    $script:currentIcon = $icon
    if ($old) { $old.Dispose() }
}

# ---------- Panel de detalles ----------
function Get-Font([single]$pt, [string]$style = 'Regular') {
    $k = "$pt|$style"
    if (-not $script:fonts.ContainsKey($k)) {
        $script:fonts[$k] = New-Object System.Drawing.Font('Segoe UI', $pt, [System.Drawing.FontStyle]$style, [System.Drawing.GraphicsUnit]::Point)
    }
    return $script:fonts[$k]
}

function Format-Ago {
    if (-not $script:fetchedAt) { return 'Sin datos todavía' }
    $m = [int][math]::Floor(((Get-Date) - $script:fetchedAt).TotalMinutes)
    if ($m -lt 1) { return 'Actualizado ahora mismo' }
    if ($m -lt 60) { return "Actualizado hace $m min" }
    if ($m -lt 1440) { return 'Actualizado hace {0} h' -f [int][math]::Floor($m / 60) }
    return 'Actualizado el ' + $script:fetchedAt.ToString('d MMM, HH:mm', $Es)
}

function Format-Reset($dt) {
    if (-not $dt) { return '' }
    $now = Get-Date
    $d = $dt - $now
    if ($d.TotalSeconds -le 0) { $rel = 'en breve' }
    elseif ($d.Days -gt 0) { $rel = 'en {0} d {1} h' -f $d.Days, $d.Hours }
    elseif ($d.Hours -gt 0) { $rel = 'en {0} h {1} min' -f $d.Hours, $d.Minutes }
    else { $rel = 'en {0} min' -f [math]::Max(1, $d.Minutes) }
    if ($dt.Date -eq $now.Date) { $abs = 'hoy ' + $dt.ToString('HH:mm') }
    elseif ($dt.Date -eq $now.Date.AddDays(1)) { $abs = 'mañana ' + $dt.ToString('HH:mm') }
    else { $abs = $dt.ToString('ddd d MMM, HH:mm', $Es) }
    return "Se reinicia $rel · $abs"
}

# Dibuja (o solo mide, si $draw es $false) el contenido del panel. Devuelve la altura.
function Invoke-PanelLayout($g, [bool]$draw, [single]$W) {
    $S = $script:S; $pal = $script:pal
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $pad = 18 * $S; $x = $pad; $iw = $W - 2 * $pad; $y = 16 * $S
    $hits = @()
    $bFg = New-Object System.Drawing.SolidBrush $pal.Fg
    $bSub = New-Object System.Drawing.SolidBrush $pal.Sub
    $bAcc = New-Object System.Drawing.SolidBrush $pal.Accent
    $bWarn = New-Object System.Drawing.SolidBrush $pal.Warn
    $bTrack = New-Object System.Drawing.SolidBrush $pal.Track

    $fTitle = Get-Font 12 'Bold'; $fName = Get-Font 10; $fPct = Get-Font 10 'Bold'; $fSmall = Get-Font 8.5

    if ($draw) { $g.DrawString('Uso de Claude', $fTitle, $bFg, $x, $y) }
    $y += $fTitle.GetHeight($g) + 4 * $S

    if ($script:status) {
        $sz = $g.MeasureString($script:status, $fSmall, [int]$iw)
        if ($draw) { $g.DrawString($script:status, $fSmall, $bWarn, (New-Object System.Drawing.RectangleF $x, $y, $iw, ($sz.Height + 2))) }
        $y += $sz.Height + 2 * $S
    }
    $y += 10 * $S

    $limits = Get-Limits
    if ($limits.Count -eq 0) {
        if ($draw) { $g.DrawString('Todavía no hay datos de uso.', $fName, $bSub, $x, $y) }
        $y += $fName.GetHeight($g) + 14 * $S
    }
    foreach ($l in $limits) {
        $pctTxt = '{0}%' -f [int][math]::Round($l.Pct)
        if ($draw) {
            $g.DrawString($l.Name, $fName, $bFg, $x, $y)
            $pw = $g.MeasureString($pctTxt, $fPct).Width
            $g.DrawString($pctTxt, $fPct, $bFg, ($x + $iw - $pw + 2 * $S), $y)
        }
        $y += $fName.GetHeight($g) + 6 * $S

        $bh = [single](6 * $S)
        if ($draw) {
            $tp = New-RoundedPath $x $y $iw $bh ($bh / 2)
            $g.FillPath($bTrack, $tp); $tp.Dispose()
            $fill = [single]($iw * [math]::Min(100, [math]::Max(0, $l.Pct)) / 100)
            if ($fill -gt 0) {
                $fill = [single][math]::Max($fill, $bh)
                $fb = New-Object System.Drawing.SolidBrush (Get-PctColor $l.Pct)
                $fp = New-RoundedPath $x $y $fill $bh ($bh / 2)
                $g.FillPath($fb, $fp); $fp.Dispose(); $fb.Dispose()
            }
        }
        $y += $bh + 6 * $S

        $rt = Format-Reset $l.Reset
        if ($rt) {
            if ($draw) { $g.DrawString($rt, $fSmall, $bSub, $x, $y) }
            $y += $fSmall.GetHeight($g)
        }
        $y += 14 * $S
    }

    $bd = Get-Breakdown
    if ($bd.Count -gt 0) {
        $txt = 'Esta semana: ' + ($bd -join ' · ')
        $sz = $g.MeasureString($txt, $fSmall, [int]$iw)
        if ($draw) { $g.DrawString($txt, $fSmall, $bSub, (New-Object System.Drawing.RectangleF $x, $y, $iw, ($sz.Height + 2))) }
        $y += $sz.Height + 12 * $S
    }

    if ($draw) {
        $pen = New-Object System.Drawing.Pen $pal.Line, ([single][math]::Max(1, $S))
        $g.DrawLine($pen, 0, $y, $W, $y); $pen.Dispose()
    }
    $y += 10 * $S

    $ago = Format-Ago
    $l1 = 'Actualizar'; $l2 = 'claude.ai'
    $w1 = $g.MeasureString($l1, $fSmall).Width; $w2 = $g.MeasureString($l2, $fSmall).Width
    $fh = $fSmall.GetHeight($g)
    $x1 = $x + $iw - $w1 + 3 * $S
    $x2 = $x1 - 14 * $S - $w2
    if ($draw) {
        $g.DrawString($ago, $fSmall, $bSub, $x, $y)
        $g.DrawString($l2, $fSmall, $bAcc, $x2, $y)
        $g.DrawString($l1, $fSmall, $bAcc, $x1, $y)
    }
    $hits += @{ Rect = (New-Object System.Drawing.RectangleF ($x1 - 4 * $S), ($y - 4 * $S), ($w1 + 8 * $S), ($fh + 8 * $S)); Action = 'refresh' }
    $hits += @{ Rect = (New-Object System.Drawing.RectangleF ($x2 - 4 * $S), ($y - 4 * $S), ($w2 + 8 * $S), ($fh + 8 * $S)); Action = 'web' }
    $y += $fh + 14 * $S

    foreach ($b in @($bFg, $bSub, $bAcc, $bWarn, $bTrack)) { $b.Dispose() }
    $script:hit = $hits
    return [int][math]::Ceiling($y)
}

function Close-Panel {
    if ($script:panel) {
        $p = $script:panel
        $script:panel = $null
        $script:panelClosed = Get-Date
        try { $p.Close() } catch { }   # Close() libera un formulario no modal
    }
}

function Update-PanelInPlace($f) {
    $g = $f.CreateGraphics()
    $H = Invoke-PanelLayout $g $false $f.ClientSize.Width
    $g.Dispose()
    $bottom = $f.Bottom
    $wa = [System.Windows.Forms.Screen]::FromControl($f).WorkingArea
    $f.Height = $H
    $f.Top = [math]::Max($wa.Top, [math]::Min($bottom - $H, $wa.Bottom - $H))
    $f.Invalidate()
}

function Show-Panel {
    Close-Panel
    $script:pal = Get-Palette
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.BackColor = $script:pal.Bg
    $f.KeyPreview = $true
    $f.Text = 'Uso de Claude'
    $f.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($f, $true, $null)

    $g = $f.CreateGraphics()
    $script:S = $g.DpiX / 96.0
    $W = [single](330 * $script:S)
    $H = Invoke-PanelLayout $g $false $W
    $g.Dispose()
    $f.Size = New-Object System.Drawing.Size ([int]$W), $H

    # Colocar junto al icono, respetando el area de trabajo (barra vertical incluida).
    $cur = [System.Windows.Forms.Cursor]::Position
    $scr = [System.Windows.Forms.Screen]::FromPoint($cur)
    $wa = $scr.WorkingArea; $bd = $scr.Bounds
    $gap = [int](10 * $script:S)
    if ($wa.Left -gt $bd.Left) { $px = $wa.Left + $gap }
    elseif ($wa.Right -lt $bd.Right) { $px = $wa.Right - $f.Width - $gap }
    else { $px = $cur.X - [int]($f.Width / 2) }
    if ($wa.Top -gt $bd.Top) { $py = $wa.Top + $gap }
    elseif ($wa.Bottom -lt $bd.Bottom) { $py = $wa.Bottom - $f.Height - $gap }
    else { $py = $cur.Y - $f.Height + [int](20 * $script:S) }
    $px = [math]::Max($wa.Left + $gap, [math]::Min($px, $wa.Right - $f.Width - $gap))
    $py = [math]::Max($wa.Top + $gap, [math]::Min($py, $wa.Bottom - $f.Height - $gap))
    $f.Location = New-Object System.Drawing.Point ([int]$px), ([int]$py)

    $f.Add_Paint({ param($s, $e) Invoke-Safe 'pintar panel' { [void](Invoke-PanelLayout $e.Graphics $true $s.ClientSize.Width) } })
    $f.Add_Deactivate({ Invoke-Safe 'cerrar panel' { Close-Panel } })
    $f.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Close-Panel } })
    $f.Add_MouseMove({
        param($s, $e)
        $over = $false
        foreach ($h in $script:hit) { if ($h.Rect.Contains([single]$e.X, [single]$e.Y)) { $over = $true } }
        $s.Cursor = if ($over) { [System.Windows.Forms.Cursors]::Hand } else { [System.Windows.Forms.Cursors]::Default }
    })
    $f.Add_MouseClick({
        param($s, $e)
        Invoke-Safe 'clic en panel' {
            foreach ($h in $script:hit) {
                if ($h.Rect.Contains([single]$e.X, [single]$e.Y)) {
                    if ($h.Action -eq 'refresh') { Invoke-Fetch; Update-Tray; Update-PanelInPlace $s }
                    elseif ($h.Action -eq 'web') { Close-Panel; Start-Process 'https://claude.ai/settings/usage' }
                    return
                }
            }
        }
    })
    $f.Add_Shown({
        param($s, $e)
        Invoke-Safe 'esquinas' {
            $v = 2  # DWMWCP_ROUND (Windows 11)
            [void][TrayNative]::DwmSetWindowAttribute($s.Handle, 33, [ref]$v, 4)
        }
        [void][TrayNative]::SetForegroundWindow($s.Handle)
        $s.Activate()
    })

    $script:panel = $f
    $f.Show()
}

function Switch-Panel {
    if ($script:panel) { Close-Panel; return }
    # Al hacer clic en el icono con el panel abierto, el panel ya se cerro al perder el foco.
    if (((Get-Date) - $script:panelClosed).TotalMilliseconds -lt 400) { return }
    if ((-not $script:fetchedAt) -or ((Get-Date) - $script:fetchedAt).TotalSeconds -gt 60) { Invoke-Fetch; Update-Tray }
    Show-Panel
}

# tests/Preview.ps1 carga solo las funciones
if ($env:CLAUDE_TRAY_LIB) { return }

$createdNew = $false
$script:mutex = New-Object System.Threading.Mutex($true, 'Local\ClaudeUsageTray', [ref]$createdNew)
if (-not $createdNew) { exit 3 }

$exitCode = 0
try {
    Read-Cache

    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $miShow = $menu.Items.Add('Ver uso')
    $miRefresh = $menu.Items.Add('Actualizar ahora')
    $miWeb = $menu.Items.Add('Abrir claude.ai/settings/usage')
    [void]$menu.Items.Add('-')
    $miQuit = $menu.Items.Add('Salir')
    $miShow.Font = New-Object System.Drawing.Font($miShow.Font, [System.Drawing.FontStyle]::Bold)

    $miShow.Add_Click({ Invoke-Safe 'ver uso' { Show-Panel } })
    $miRefresh.Add_Click({ Invoke-Safe 'actualizar' { Invoke-Fetch; Update-Tray } })
    $miWeb.Add_Click({ Invoke-Safe 'web' { Start-Process 'https://claude.ai/settings/usage' } })
    $miQuit.Add_Click({
        Write-Log 'Cerrado por el usuario.'
        $script:tray.Visible = $false
        [System.Windows.Forms.Application]::Exit()
    })
    $script:tray.ContextMenuStrip = $menu
    $script:tray.Add_MouseClick({
        param($s, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-Safe 'clic en icono' { Switch-Panel } }
    })

    Update-Tray
    $script:tray.Visible = $true

    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 2000
    $script:timer.Add_Tick({
        Invoke-Safe 'temporizador' {
            $script:timer.Interval = 30000
            if ((Get-Date) -ge $script:nextFetch) { Invoke-Fetch }
            Update-Tray
        }
    })
    $script:timer.Start()

    Write-Log 'Iniciado.'
    [System.Windows.Forms.Application]::Run((New-Object System.Windows.Forms.ApplicationContext))
} catch {
    Write-Log ('Fallo grave: ' + $_.Exception.ToString())
    $exitCode = 1
} finally {
    try { if ($script:timer) { $script:timer.Stop() } } catch { }
    try { if ($script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch { }
    try { $script:mutex.ReleaseMutex() } catch { }
}
exit $exitCode
