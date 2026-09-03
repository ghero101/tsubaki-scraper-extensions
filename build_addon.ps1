<#
.SYNOPSIS
  Validate, version, and package a Tsubaki extension into dist/.

.DESCRIPTION
  Standardizes the addon build/publish workflow (see CONTRIBUTING.md). It:
    1. Validates manifest.json against the rules the Rust scraper enforces at
       load time (invalid values make the scraper SILENTLY skip the extension).
    2. Optionally bumps the manifest patch version.
    3. Zips the source folder (with the folder-prefix layout the installer
       expects) into dist/<name>/<name>_<ver>.zip and refreshes _latest.zip.

.EXAMPLE
  ./build_addon.ps1 -Source mangapill-rhai -Bump
  ./build_addon.ps1 -Validate            # validate every source manifest, no build
  ./build_addon.ps1 -Source toonclash-rhai

.NOTES
  Run from an extension repo root.
#>
[CmdletBinding()]
param(
    [string]$Source,
    [switch]$Bump,
    [switch]$Validate
)

$ErrorActionPreference = 'Stop'
$repo = $PSScriptRoot
$srcRoot = Join-Path $repo 'sources'
$distRoot = Join-Path $repo 'dist'

# Values the Rust manifest parser accepts (tsubaki-scraper/src/plugins/manifest.rs).
# Anything else -> "unknown variant" parse error -> extension is NOT loaded.
$ValidLevels = @('http_only', 'browser_automation')
$ValidTech   = @('rhai', 'lua', 'wasm', 'native', 'python')

function Test-Manifest {
    param([string]$Dir)
    $name = Split-Path $Dir -Leaf
    $mPath = Join-Path $Dir 'manifest.json'
    $errs = @()
    if (-not (Test-Path $mPath)) { return @("[$name] missing manifest.json") }
    try { $m = Get-Content $mPath -Raw | ConvertFrom-Json } catch { return @("[$name] manifest.json is not valid JSON: $($_.Exception.Message)") }

    if (-not $m.id)      { $errs += "[$name] manifest.id is empty" }
    if (-not $m.version) { $errs += "[$name] manifest.version is empty" }
    if (-not $m.name)    { $errs += "[$name] manifest.name is empty" }

    $lvl = $m.capabilities.level
    if ($lvl -and ($lvl -notin $ValidLevels)) {
        $errs += "[$name] capabilities.level='$lvl' is INVALID (allowed: $($ValidLevels -join ', ')) -> scraper will refuse to load this extension"
    }
    if ($m.technology -and ($m.technology -notin $ValidTech)) {
        $errs += "[$name] technology='$($m.technology)' is unusual (expected: $($ValidTech -join ', '))"
    }

    # entry_point.file must exist
    $entry = $m.entry_point.file
    if ($entry -and -not (Test-Path (Join-Path $Dir $entry))) {
        $errs += "[$name] entry_point.file '$entry' not found on disk"
    }
    # icon hygiene
    if (-not $m.icon_path -and -not $m.icon_url) { $errs += "[$name] no icon_path or icon_url declared" }
    if ($null -eq $m.nsfw) { $errs += "[$name] WARN: nsfw flag not declared (set true for adult/booru/hentai sources, else false)" }
    # The scraper derives implemented features from this manifest block (NOT from
    # which script functions exist). Missing it => every feature reports
    # "not implemented" and the connector silently fails the health harness.
    if (-not $m.features) { $errs += "[$name] missing top-level 'features' block -> scraper reports all features unimplemented" }
    return $errs
}

if ($Validate) {
    $all = Get-ChildItem $srcRoot -Directory
    $bad = 0
    foreach ($d in $all) {
        $e = Test-Manifest -Dir $d.FullName
        if ($e) { $bad++; $e | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
    }
    Write-Host ""
    if ($bad -eq 0) { Write-Host "All $($all.Count) manifests valid." -ForegroundColor Green }
    else { Write-Host "$bad of $($all.Count) manifests have issues (see above)." -ForegroundColor Red }
    return
}

if (-not $Source) { throw "Specify -Source <dirname> (or -Validate to check all manifests)." }
$srcDir = Join-Path $srcRoot $Source
if (-not (Test-Path $srcDir)) { throw "Source folder not found: $srcDir" }

# Validate first — never ship a manifest the scraper will reject.
$issues = Test-Manifest -Dir $srcDir
$fatal = $issues | Where-Object { $_ -notmatch 'WARN' }
if ($fatal) { $fatal | ForEach-Object { Write-Host $_ -ForegroundColor Red }; throw "Manifest validation failed for $Source — fix the above before building." }
$issues | Where-Object { $_ -match 'WARN' } | ForEach-Object { Write-Host $_ -ForegroundColor Yellow }

$mPath = Join-Path $srcDir 'manifest.json'
$m = Get-Content $mPath -Raw | ConvertFrom-Json

if ($Bump) {
    $parts = $m.version.Split('.')
    $parts[-1] = [string]([int]$parts[-1] + 1)
    $newVer = $parts -join '.'
    (Get-Content $mPath -Raw) -replace ('"version"\s*:\s*"' + [regex]::Escape($m.version) + '"'), ('"version": "' + $newVer + '"') | Set-Content $mPath -NoNewline -Encoding utf8
    Write-Host "Bumped version $($m.version) -> $newVer" -ForegroundColor Cyan
    $m.version = $newVer
}

$verTag = $m.version.Replace('.', '-')
$distDir = Join-Path $distRoot $Source
New-Item -ItemType Directory -Force -Path $distDir | Out-Null
$verZip   = Join-Path $distDir "$Source`_$verTag.zip"
$latestZip = Join-Path $distDir "$Source`_latest.zip"
Remove-Item $verZip, $latestZip -ErrorAction SilentlyContinue
Compress-Archive -Path $srcDir -DestinationPath $verZip -CompressionLevel Optimal
Copy-Item $verZip $latestZip -Force
Write-Host "Built $verZip and refreshed _latest.zip" -ForegroundColor Green
Write-Host "Next: git add + commit + push, then update via the UI." -ForegroundColor DarkGray
