# =============================================================================
# Tsubaki Extensions Build Script (Windows PowerShell)
# =============================================================================
# This script:
#   1. Reads manifest.json from each extension to get version info
#   2. Updates index.json with current versions and download URLs
#   3. Creates versioned zip files (e.g., flamecomics-rhai_1-1-5.zip)
#   4. Creates _latest.zip copies for convenience
#   5. Organizes everything in dist/{extension-name}/ folders
# =============================================================================

param(
    [switch]$Clean,
    [switch]$Help,
    [string]$Single
)

# Script configuration
$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$SourcesDir = Join-Path $ScriptDir "sources"
$DistDir = Join-Path $ScriptDir "dist"
$IndexFile = Join-Path $ScriptDir "index.json"

# GitHub raw URL base for download URLs
$GitHubRawBase = "https://raw.githubusercontent.com/ghero101/tsubaki-scraper-extensions/master"

# Store built extensions for index update
$Script:BuiltExtensions = @()

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Show-Help {
    Write-Host @"
Tsubaki Extensions Build Script (Windows)

Usage: .\build.ps1 [options]

Options:
    -Help       Show this help message
    -Clean      Clean dist directory before building
    -Single     Build only a single extension (e.g., -Single "flamecomics-rhai")

Examples:
    .\build.ps1                           # Build all extensions
    .\build.ps1 -Clean                    # Clean and rebuild all
    .\build.ps1 -Single "mangadex-rhai"   # Build only mangadex-rhai

"@
}

function Get-ManifestValue {
    param(
        [string]$ManifestPath,
        [string]$Key
    )

    try {
        $manifest = Get-Content $ManifestPath -Raw | ConvertFrom-Json
        return $manifest.$Key
    }
    catch {
        return $null
    }
}

function ConvertTo-VersionFilename {
    param([string]$Version)
    return $Version -replace '\.', '-'
}

function Build-Extension {
    param([string]$ExtDir)

    $extName = Split-Path $ExtDir -Leaf
    $manifestFile = Join-Path $ExtDir "manifest.json"

    # Check if manifest exists
    if (-not (Test-Path $manifestFile)) {
        Write-ColorOutput "  Skipping $extName (no manifest.json)" "Yellow"
        return
    }

    # Read manifest values
    $extId = Get-ManifestValue $manifestFile "id"
    $version = Get-ManifestValue $manifestFile "version"
    $name = Get-ManifestValue $manifestFile "name"
    $description = Get-ManifestValue $manifestFile "description"
    $addonType = Get-ManifestValue $manifestFile "addon_type"
    $technology = Get-ManifestValue $manifestFile "technology"
    $nsfw = Get-ManifestValue $manifestFile "nsfw"

    if (-not $version) {
        Write-ColorOutput "  Skipping $extName (no version in manifest)" "Yellow"
        return
    }

    $versionFilename = ConvertTo-VersionFilename $version
    $extDistDir = Join-Path $DistDir $extName
    $zipFilename = "${extName}_${versionFilename}.zip"
    $zipPath = Join-Path $extDistDir $zipFilename
    $latestPath = Join-Path $extDistDir "${extName}_latest.zip"

    Write-ColorOutput "  Building: $name ($extName) v$version" "Green"

    # Create extension dist directory
    New-Item -ItemType Directory -Force -Path $extDistDir | Out-Null

    # Check if this version already exists
    if (Test-Path $zipPath) {
        Write-ColorOutput "    Version $version already exists, rebuilding..." "Yellow"
        Remove-Item $zipPath -Force
    }

    # Remove latest if exists
    if (Test-Path $latestPath) {
        Remove-Item $latestPath -Force
    }

    # Create the zip file
    # PowerShell's Compress-Archive needs special handling for folder structure
    $tempZipPath = Join-Path $env:TEMP "$zipFilename"

    # Create zip with folder structure
    try {
        # Remove temp file if exists
        if (Test-Path $tempZipPath) {
            Remove-Item $tempZipPath -Force
        }

        # Compress the extension folder
        Compress-Archive -Path $ExtDir -DestinationPath $tempZipPath -Force

        # Move to final location
        Move-Item $tempZipPath $zipPath -Force

        # Create latest.zip copy
        Copy-Item $zipPath $latestPath -Force

        # Get file size
        $size = (Get-Item $zipPath).Length
        $sizeKB = [math]::Round($size / 1KB, 2)
        Write-Host "    Created: $zipFilename ($sizeKB KB)"

        # Store for index update
        $Script:BuiltExtensions += [PSCustomObject]@{
            ExtId = $extId
            ExtName = $extName
            Version = $version
            ZipFilename = $zipFilename
            Name = $name
            Description = $description
            AddonType = $addonType
            Technology = $technology
            Nsfw = $nsfw
        }
    }
    catch {
        Write-ColorOutput "    Error creating zip: $_" "Red"
    }
}

function Update-Index {
    Write-Host ""
    Write-ColorOutput "Updating index.json..." "Cyan"

    if (-not (Test-Path $IndexFile)) {
        Write-ColorOutput "Error: index.json not found" "Red"
        return
    }

    try {
        $index = Get-Content $IndexFile -Raw | ConvertFrom-Json
        $timestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        $updatedCount = 0

        foreach ($ext in $Script:BuiltExtensions) {
            $downloadUrl = "$GitHubRawBase/dist/$($ext.ExtName)/$($ext.ZipFilename)"
            $manifestUrl = "$GitHubRawBase/sources/$($ext.ExtName)/manifest.json"

            # Find and update the addon in the index
            foreach ($addon in $index.addons) {
                if ($addon.id -eq $ext.ExtId) {
                    $addon.version = $ext.Version
                    $addon.latest_version = $ext.Version
                    $addon.download_url = $downloadUrl
                    $addon.manifest_url = $manifestUrl

                    # Propagate human-readable manifest fields so the index doesn't
                    # drift from the source as descriptions / nsfw / etc. evolve.
                    # Only overwrite when the manifest actually provided a value.
                    if ($ext.Name) { $addon.name = $ext.Name }
                    if ($ext.Description) { $addon.description = $ext.Description }
                    if ($ext.AddonType) { $addon.addon_type = $ext.AddonType }
                    if ($ext.Technology) { $addon.technology = $ext.Technology }
                    if ($null -ne $ext.Nsfw) { $addon.nsfw = $ext.Nsfw }

                    # Add/update version entry
                    if (-not $addon.versions) {
                        $addon | Add-Member -NotePropertyName "versions" -NotePropertyValue @{} -Force
                    }

                    # Preserve original released_at on rebuilds — clients use it
                    # to display "what's new" timelines. Only set when the version
                    # entry is first created.
                    $existing = $addon.versions.PSObject.Properties[$ext.Version]
                    $releasedAt = if ($existing -and $existing.Value.released_at) { $existing.Value.released_at } else { $timestamp }
                    $addon.versions | Add-Member -NotePropertyName $ext.Version -NotePropertyValue @{
                        download_url = $downloadUrl
                        released_at = $releasedAt
                        changelog = if ($existing -and $existing.Value.changelog) { $existing.Value.changelog } else { "Updated" }
                    } -Force

                    $updatedCount++
                    break
                }
            }
        }

        # Bump index version only when something actually changed. Empty bumps
        # are noise — clients use the version to decide whether to refetch.
        if ($updatedCount -gt 0) {
            $index.version = ($index.version -as [int]) + 1
            $index.updated_at = $timestamp
            # Write back to file with proper formatting
            $index | ConvertTo-Json -Depth 10 | Set-Content $IndexFile -Encoding UTF8
            Write-ColorOutput "  Updated $updatedCount extensions in index.json (version $($index.version))" "Green"
        } else {
            Write-ColorOutput "  No index entries updated (version stays at $($index.version))" "Yellow"
        }

        # Consistency check: every built source should have matched an index entry.
        # If $updatedCount < built count, some sources silently skipped indexing
        # (usually an id mismatch between source manifest and index.json — see NOTES.md).
        $builtCount = $Script:BuiltExtensions.Count
        if ($updatedCount -lt $builtCount) {
            Write-Host ""
            Write-ColorOutput "  WARNING: $($builtCount - $updatedCount) source(s) built but NOT indexed:" "Yellow"
            $indexedIds = @($index.addons | ForEach-Object { $_.id })
            foreach ($ext in $Script:BuiltExtensions) {
                if ($indexedIds -notcontains $ext.ExtId) {
                    Write-ColorOutput "    - source '$($ext.ExtName)' has manifest id '$($ext.ExtId)' but no matching index entry" "Yellow"
                }
            }
            Write-ColorOutput "  Fix: align the source manifest id to the index entry id, or vice versa." "Yellow"
        }

        # Reverse check: every index entry should have a matching built source.
        # Only meaningful on a full build — skip in -Single mode where most
        # entries are intentionally not in $BuiltExtensions.
        $builtIds = @($Script:BuiltExtensions | ForEach-Object { $_.ExtId })
        $orphans = @()
        if ($Script:IsFullBuild) {
            $orphans = @($index.addons | Where-Object { $builtIds -notcontains $_.id })
        }
        if ($orphans.Count -gt 0) {
            Write-Host ""
            Write-ColorOutput "  WARNING: $($orphans.Count) index entry/entries have no source folder:" "Yellow"
            foreach ($o in $orphans) {
                Write-ColorOutput "    - '$($o.id)' is in index.json but cannot be rebuilt (sources/ missing)" "Yellow"
            }
            Write-ColorOutput "  Fix: restore the source folder, or remove the orphan index entry + dist/ folder." "Yellow"
        }
    }
    catch {
        Write-ColorOutput "Error updating index.json: $_" "Red"
    }
}

function Start-Build {
    $Script:IsFullBuild = $true
    Write-ColorOutput "==============================================================================" "Cyan"
    Write-ColorOutput "                    Tsubaki Extensions Build Script                          " "Cyan"
    Write-ColorOutput "==============================================================================" "Cyan"
    Write-Host ""
    Write-ColorOutput "Sources directory: $SourcesDir" "Cyan"
    Write-ColorOutput "Dist directory: $DistDir" "Cyan"
    Write-Host ""

    # Create dist directory if it doesn't exist
    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

    Write-ColorOutput "Building extensions..." "Cyan"

    # Process each extension directory
    Get-ChildItem -Path $SourcesDir -Directory | ForEach-Object {
        Build-Extension $_.FullName
    }

    # Update index.json
    Update-Index

    Write-Host ""
    Write-ColorOutput "==============================================================================" "Cyan"
    Write-ColorOutput "Build complete!" "Green"
    Write-Host ""
    Write-Host "Built $($Script:BuiltExtensions.Count) extensions"
    Write-Host ""
    Write-ColorOutput "Next steps:" "Yellow"
    Write-Host "  1. Review changes: git status"
    Write-Host "  2. Commit: git add -A && git commit -m 'Update extensions'"
    Write-Host "  3. Push: git push"
    Write-ColorOutput "==============================================================================" "Cyan"
}

# Main entry point
if ($Help) {
    Show-Help
    exit 0
}

if ($Clean) {
    Write-ColorOutput "Cleaning dist directory..." "Yellow"
    if (Test-Path $DistDir) {
        Remove-Item "$DistDir\*" -Recurse -Force
    }
}

if ($Single) {
    $singlePath = Join-Path $SourcesDir $Single
    if (Test-Path $singlePath) {
        New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
        Build-Extension $singlePath
        Update-Index
    }
    else {
        Write-ColorOutput "Error: Extension '$Single' not found" "Red"
        exit 1
    }
}
else {
    Start-Build
}
