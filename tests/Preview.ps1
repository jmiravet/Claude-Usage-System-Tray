# Renders the panel and icons to PNG without touching the tray, for visual review.
# Usage: powershell -File tests\Preview.ps1 [output-folder]
param([string]$OutDir = $PWD)

$env:CLAUDE_TRAY_LIB = '1'
. (Join-Path $PSScriptRoot '..\ClaudeUsageTray.ps1')

Read-Cache
if (-not $script:data) { Invoke-Fetch }
if (-not (Get-Limit 'session')) { throw "No usage data: $script:status" }

# Panel
$script:pal = Get-Palette
$script:S = 1.5
$W = [single](330 * $script:S)
$gm = [System.Drawing.Graphics]::FromImage((New-Object System.Drawing.Bitmap 1, 1))
$H = Invoke-PanelLayout $gm $false $W
$bmp = New-Object System.Drawing.Bitmap ([int]$W), $H
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear($script:pal.Bg)
[void](Invoke-PanelLayout $g $true $W)
$bmp.Save((Join-Path $OutDir 'panel.png'))

# Icons: actual size (24 px) on dark and light taskbars, plus 4x zoom
$cases = @(@(0, 'ok'), @(12, 'ok'), @(35, 'ok'), @(62, 'ok'), @(78, 'ok'), @(95, 'ok'), @(100, 'ok'), @(40, 'stale'), @(0, 'error'))
$cell = 112
$strip = New-Object System.Drawing.Bitmap ($cell * $cases.Count), 200
$gs = [System.Drawing.Graphics]::FromImage($strip)
$gs.Clear([System.Drawing.Color]::FromArgb(32, 32, 32))
$gs.FillRectangle((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(238, 238, 238))), 0, 40, $strip.Width, 40)
$gs.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$gs.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$font = New-Object System.Drawing.Font('Segoe UI', 8)
for ($i = 0; $i -lt $cases.Count; $i++) {
    $ib = New-IconBitmap 24 $cases[$i][0] $cases[$i][1]
    $x0 = $i * $cell
    $gs.DrawImage($ib, $x0 + 44, 8, 24, 24)
    $gs.DrawImage($ib, $x0 + 44, 48, 24, 24)
    $gs.DrawImage($ib, $x0 + 8, 84, 96, 96)
    $gs.DrawString(('{0}% {1}' -f $cases[$i][0], $cases[$i][1]), $font, [System.Drawing.Brushes]::Gray, $x0 + 8, 182)
}
$strip.Save((Join-Path $OutDir 'icons.png'))
Write-Host "Saved panel.png and icons.png to $OutDir"
