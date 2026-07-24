# =============================================================================
# Generate per-source icon.png files
# =============================================================================
# Every plugin manifest references `icon.png` but the file is missing for all
# 53 sources. This script generates a distinct 128x128 PNG icon per source:
#   - 2-3 letter abbreviation from the manifest's `name`
#   - background colour derived from a hash of the addon `id` so each source
#     gets a stable, distinct look without manual design work
#   - white text, rounded square background
#
# Run:
#   pwsh ./tools/generate-icons.ps1
#   pwsh ./tools/generate-icons.ps1 -Force        # overwrite existing icons
#   pwsh ./tools/generate-icons.ps1 -Single <id>  # one source only
# =============================================================================

param(
    [switch]$Force,
    [string]$Single
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourcesDir  = Join-Path (Split-Path -Parent $ScriptDir) "sources"
$IconSize    = 128

# Palette of distinct background colours. We pick from this deterministically
# by hashing the addon id so a given source always gets the same colour.
$Palette = @(
    [System.Drawing.Color]::FromArgb(255, 0xE53935),  # red
    [System.Drawing.Color]::FromArgb(255, 0xD81B60),  # pink
    [System.Drawing.Color]::FromArgb(255, 0x8E24AA),  # purple
    [System.Drawing.Color]::FromArgb(255, 0x5E35B1),  # deep purple
    [System.Drawing.Color]::FromArgb(255, 0x3949AB),  # indigo
    [System.Drawing.Color]::FromArgb(255, 0x1E88E5),  # blue
    [System.Drawing.Color]::FromArgb(255, 0x039BE5),  # light blue
    [System.Drawing.Color]::FromArgb(255, 0x00ACC1),  # cyan
    [System.Drawing.Color]::FromArgb(255, 0x00897B),  # teal
    [System.Drawing.Color]::FromArgb(255, 0x43A047),  # green
    [System.Drawing.Color]::FromArgb(255, 0x7CB342),  # light green
    [System.Drawing.Color]::FromArgb(255, 0xFB8C00),  # orange
    [System.Drawing.Color]::FromArgb(255, 0xF4511E),  # deep orange
    [System.Drawing.Color]::FromArgb(255, 0x6D4C41),  # brown
    [System.Drawing.Color]::FromArgb(255, 0x546E7A)   # blue grey
)

function Get-Initials {
    param([string]$Name)
    # Multi-word names: first letter of each word ("Manga Updates" → "MU").
    # CamelCase / PascalCase single-word names: extract capital letters
    # ("MangaDex" → "MD", "MyAnimeList" → "MAL", "AniList" → "AL").
    # Lowercase single-word names: first two letters ("nhentai" → "NH").
    # Caps are limited to 3 chars so they fit at the chosen font size.
    $clean = $Name -replace '[^\w\s]', ''
    # @(...) forces a single-element array — PowerShell otherwise unwraps the
    # pipe result to a bare string and `$parts[0]` then indexes a character
    # instead of returning the word.
    $parts = @($clean -split '\s+' | Where-Object { $_ -ne '' })

    if ($parts.Count -ge 2) {
        $initials = -join ($parts | ForEach-Object { $_.Substring(0, 1).ToUpper() })
        if ($initials.Length -gt 3) { $initials = $initials.Substring(0, 3) }
        return $initials
    }

    if ($parts.Count -eq 1) {
        $word = $parts[0]
        # Extract capital letters from PascalCase/camelCase
        $caps = -join ([regex]::Matches($word, '[A-Z]') | ForEach-Object { $_.Value })
        if ($caps.Length -ge 2) {
            if ($caps.Length -gt 3) { $caps = $caps.Substring(0, 3) }
            return $caps
        }
        # Fall back to first 2 chars (handles "nhentai", "kagane", etc.)
        if ($word.Length -ge 2) {
            return $word.Substring(0, 2).ToUpper()
        }
    }

    if ($clean.Length -ge 1) {
        return $clean.Substring(0, [Math]::Min(2, $clean.Length)).ToUpper()
    }
    "?"
}

function Get-PaletteColor {
    param([string]$Id)
    # Stable hash → palette index. Sum char codes; modulo palette length.
    $sum = 0
    foreach ($ch in $Id.ToCharArray()) { $sum += [int]$ch }
    $Palette[$sum % $Palette.Count]
}

function New-IconImage {
    param(
        [string]$Initials,
        [System.Drawing.Color]$BgColor,
        [string]$OutputPath
    )

    $bmp = New-Object System.Drawing.Bitmap $IconSize, $IconSize
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

    # Filled rounded-square background
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $radius = 24
    $rect = [System.Drawing.Rectangle]::new(0, 0, $IconSize, $IconSize)
    $path.AddArc($rect.X, $rect.Y, $radius, $radius, 180, 90)
    $path.AddArc($rect.X + $rect.Width - $radius, $rect.Y, $radius, $radius, 270, 90)
    $path.AddArc($rect.X + $rect.Width - $radius, $rect.Y + $rect.Height - $radius, $radius, $radius, 0, 90)
    $path.AddArc($rect.X, $rect.Y + $rect.Height - $radius, $radius, $radius, 90, 90)
    $path.CloseFigure()

    $brush = New-Object System.Drawing.SolidBrush $BgColor
    $g.FillPath($brush, $path)
    $brush.Dispose()
    $path.Dispose()

    # Text — pick a font size that fits regardless of initial count
    $fontSize = switch ($Initials.Length) {
        1 { 72 }
        2 { 56 }
        3 { 42 }
        default { 36 }
    }
    $font = New-Object System.Drawing.Font "Segoe UI", $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    $textBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $format = New-Object System.Drawing.StringFormat
    $format.Alignment = [System.Drawing.StringAlignment]::Center
    $format.LineAlignment = [System.Drawing.StringAlignment]::Center

    $g.DrawString($Initials, $font, $textBrush, [System.Drawing.RectangleF]::new(0, 0, $IconSize, $IconSize), $format)

    $font.Dispose()
    $textBrush.Dispose()
    $format.Dispose()
    $g.Dispose()

    $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

$generated = 0
$skipped = 0

Get-ChildItem -Path $SourcesDir -Directory | ForEach-Object {
    $sourceDir = $_.FullName
    $sourceName = $_.Name

    if ($Single -and $Single -ne $sourceName) { return }

    $manifestPath = Join-Path $sourceDir "manifest.json"
    if (-not (Test-Path $manifestPath)) { return }

    $iconPath = Join-Path $sourceDir "icon.png"
    if ((Test-Path $iconPath) -and -not $Force) {
        $skipped++
        return
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
    $name = $manifest.name
    $id = $manifest.id
    if (-not $name) { $name = $sourceName }
    if (-not $id) { $id = $sourceName }

    $initials = Get-Initials $name
    $color = Get-PaletteColor $id

    Write-Host "  $sourceName -> '$initials' on #$($color.R.ToString('X2'))$($color.G.ToString('X2'))$($color.B.ToString('X2'))"
    New-IconImage -Initials $initials -BgColor $color -OutputPath $iconPath
    $generated++
}

Write-Host ""
Write-Host "Generated: $generated icons" -ForegroundColor Green
if ($skipped -gt 0) {
    Write-Host "Skipped:   $skipped (already had icon.png, use -Force to overwrite)" -ForegroundColor Yellow
}
