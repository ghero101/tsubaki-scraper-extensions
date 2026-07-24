# =============================================================================
# Patch-bump every source manifest's version
# =============================================================================
# Reads sources/*/manifest.json, increments the patch component of `version`
# by one, writes back preserving formatting as best PowerShell can.
#
# Used when shipping a cross-cutting change (like icons) that needs every
# plugin's update mechanism to fire.
#
# Run:
#   pwsh ./tools/bump-versions.ps1
#   pwsh ./tools/bump-versions.ps1 -DryRun
# =============================================================================

param(
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourcesDir = Join-Path (Split-Path -Parent $ScriptDir) "sources"

Get-ChildItem -Path $SourcesDir -Directory | ForEach-Object {
    $manifestPath = Join-Path $_.FullName "manifest.json"
    if (-not (Test-Path $manifestPath)) { return }

    $content = Get-Content $manifestPath -Raw
    # Match `"version": "X.Y.Z"` on the first top-level occurrence. The (?m)
    # multiline + ^\s+ anchor avoids matching nested `"version"` keys (e.g.
    # inside settings_schema "1.2.0" version entries).
    $match = [regex]::Match($content, '(?m)^\s+"version"\s*:\s*"(\d+)\.(\d+)\.(\d+)"\s*,')
    if (-not $match.Success) {
        Write-Host "  $($_.Name): could not find version field" -ForegroundColor Yellow
        return
    }
    $major = [int]$match.Groups[1].Value
    $minor = [int]$match.Groups[2].Value
    $patch = [int]$match.Groups[3].Value
    $oldVer = "$major.$minor.$patch"
    $newPatch = $patch + 1
    $newVer = "$major.$minor.$newPatch"

    Write-Host "  $($_.Name): $oldVer -> $newVer"

    if (-not $DryRun) {
        # Replace just the first matched version line, preserving leading indent
        $newContent = $content.Substring(0, $match.Index) + ($match.Value -replace '"\d+\.\d+\.\d+"', "`"$newVer`"") + $content.Substring($match.Index + $match.Length)
        # Write without BOM, preserving existing line endings
        [System.IO.File]::WriteAllText($manifestPath, $newContent)
    }
}

if ($DryRun) {
    Write-Host ""
    Write-Host "Dry run — no files modified." -ForegroundColor Yellow
}
