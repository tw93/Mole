# Mole - Application-Specific Cleanup Module
# Cleans leftover data from uninstalled apps and app-specific caches

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_APPS_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_APPS_LOADED) { return }
$script:MOLE_CLEAN_APPS_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"
. "$PSScriptRoot\cache_guard.ps1"

# ============================================================================
# Orphaned App Data Detection
# ============================================================================

function Get-InstalledPrograms {
    <#
    .SYNOPSIS
        Get list of installed programs from registry
    #>
    
    $programs = @()
    
    $registryPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    
    foreach ($path in $registryPaths) {
        $items = Get-ItemProperty -Path $path -ErrorAction SilentlyContinue |
                 Where-Object { $_.DisplayName } |
                 Select-Object DisplayName, InstallLocation, Publisher
        if ($items) {
            $programs += $items
        }
    }
    
    # Also check UWP apps
    try {
        $uwpApps = Get-AppxPackage -ErrorAction SilentlyContinue | 
                   Select-Object @{N='DisplayName';E={$_.Name}}, @{N='InstallLocation';E={$_.InstallLocation}}, Publisher
        if ($uwpApps) {
            $programs += $uwpApps
        }
    }
    catch {
        Write-Debug "Could not enumerate UWP apps: $_"
    }
    
    return $programs
}

function Find-OrphanedAppData {
    <#
    .SYNOPSIS
        Find app data folders for apps that are no longer installed
    #>
    param([int]$DaysOld = 60)
    
    $installedPrograms = Get-InstalledPrograms
    $installedNames = $installedPrograms | ForEach-Object { $_.DisplayName.ToLower() }
    
    $orphanedPaths = @()
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    
    # Check common app data locations
    $appDataPaths = @(
        @{ Path = $env:APPDATA; Type = "Roaming" }
        @{ Path = $env:LOCALAPPDATA; Type = "Local" }
    )
    
    foreach ($location in $appDataPaths) {
        if (-not (Test-Path $location.Path)) { continue }
        
        $folders = Get-ChildItem -Path $location.Path -Directory -ErrorAction SilentlyContinue
        
        foreach ($folder in $folders) {
            # Skip system folders
            $skipFolders = @('Microsoft', 'Windows', 'Packages', 'Programs', 'Temp', 'Roaming')
            if ($folder.Name -in $skipFolders) { continue }
            
            # Skip if recently modified
            if ($folder.LastWriteTime -gt $cutoffDate) { continue }
            
            # Check if app is installed using stricter matching
            # Require exact match or that folder name is a clear prefix/suffix of app name
            $isInstalled = $false
            $folderLower = $folder.Name.ToLower()
            foreach ($name in $installedNames) {
                # Exact match
                if ($name -eq $folderLower) {
                    $isInstalled = $true
                    break
                }
                # Folder is prefix of app name (e.g., "chrome" matches "chrome browser")
                if ($name.StartsWith($folderLower) -and $folderLower.Length -ge 4) {
                    $isInstalled = $true
                    break
                }
                # App name is prefix of folder (e.g., "vscode" matches "vscode-data")
                if ($folderLower.StartsWith($name) -and $name.Length -ge 4) {
                    $isInstalled = $true
                    break
                }
            }
            
            if (-not $isInstalled) {
                $orphanedPaths += @{
                    Path = $folder.FullName
                    Name = $folder.Name
                    Type = $location.Type
                    Size = (Get-PathSize -Path $folder.FullName)
                    LastModified = $folder.LastWriteTime
                }
            }
        }
    }
    
    return $orphanedPaths
}

function Clear-OrphanedAppData {
    <#
    .SYNOPSIS
        Clean orphaned application data
    #>
    param([int]$DaysOld = 60)
    
    Start-Section "Orphaned app data"
    
    # @() keeps a single result an array; one hashtable alone would report
    # its key count as .Count.
    $orphaned = @(Find-OrphanedAppData -DaysOld $DaysOld)
    
    if ($orphaned.Count -eq 0) {
        Write-Info "No orphaned app data found"
        Stop-Section
        return
    }
    
    # Filter by size (only clean if > 10MB to avoid noise)
    $significantOrphans = @($orphaned | Where-Object { $_.Size -gt 10MB })
    
    if ($significantOrphans.Count -gt 0) {
        $totalSize = ($significantOrphans | Measure-Object -Property Size -Sum).Sum
        $sizeHuman = Format-ByteSize -Bytes $totalSize
        
        $noun = if ($significantOrphans.Count -eq 1) { 'folder' } else { 'folders' }
        Write-Info "Found $($significantOrphans.Count) orphaned $noun ($sizeHuman)"
        
        foreach ($orphan in $significantOrphans) {
            $orphanSize = Format-ByteSize -Bytes $orphan.Size
            $null = Remove-SafeItem -Path $orphan.Path -Description "$($orphan.Name) ($orphanSize)" -Recurse
        }
    }
    
    Stop-Section
}

# ============================================================================
# Specific Application Cleanup
# ============================================================================

function Clear-OfficeCache {
    <#
    .SYNOPSIS
        Clean Microsoft Office caches and temp files
    #>
    
    $officeCachePaths = @(
        # Office 365 / 2019 / 2021
        "$env:LOCALAPPDATA\Microsoft\Office\16.0\Wef"
        "$env:LOCALAPPDATA\Microsoft\Outlook\Offline Address Books"
        # Office temp files
        "$env:APPDATA\Microsoft\Templates\*.tmp"
        "$env:APPDATA\Microsoft\Word\*.tmp"
        "$env:APPDATA\Microsoft\Excel\*.tmp"
        "$env:APPDATA\Microsoft\PowerPoint\*.tmp"
    )
    
    foreach ($path in $officeCachePaths) {
        if ($path -like "*.tmp") {
            $parent = Split-Path -Parent $path
            if (Test-Path $parent) {
                $tmpFiles = Get-ChildItem -Path $parent -Filter "*.tmp" -File -ErrorAction SilentlyContinue
                if ($tmpFiles) {
                    $paths = $tmpFiles | ForEach-Object { $_.FullName }
                    Remove-SafeItems -Paths $paths -Description "Office temp files"
                }
            }
        }
        elseif (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Office $(Split-Path -Leaf $path)"
        }
    }
}

function Clear-OneDriveCache {
    <#
    .SYNOPSIS
        Clean OneDrive cache
    #>
    
    $oneDriveCachePaths = @(
        "$env:LOCALAPPDATA\Microsoft\OneDrive\setup\logs"
    )
    
    foreach ($path in $oneDriveCachePaths) {
        if (Test-Path $path) {
            Remove-OldFiles -Path $path -DaysOld 7 -Description "OneDrive logs"
        }
    }
}

function Clear-GoogleDriveCache {
    <#
    .SYNOPSIS
        Clean Google Drive cache
    #>
    
    $googleDriveCachePaths = @(
        "$env:LOCALAPPDATA\Google\DriveFS\Logs"
        "$env:LOCALAPPDATA\Google\DriveFS\*.tmp"
    )
    
    foreach ($path in $googleDriveCachePaths) {
        if ($path -like "*.tmp") {
            $parent = Split-Path -Parent $path
            if (Test-Path $parent) {
                $tmpFiles = Get-ChildItem -Path $parent -Filter "*.tmp" -ErrorAction SilentlyContinue
                if ($tmpFiles) {
                    $paths = $tmpFiles | ForEach-Object { $_.FullName }
                    Remove-SafeItems -Paths $paths -Description "Google Drive temp"
                }
            }
        }
        elseif (Test-Path $path) {
            Remove-OldFiles -Path $path -DaysOld 7 -Description "Google Drive logs"
        }
    }
}

function Clear-AdobeData {
    <#
    .SYNOPSIS
        Clean Adobe application caches and temp files
    #>
    
    # These media caches are shared by the editors; keep them while any owner
    # is active or unknown. The shared sink checks again after sizing.
    foreach ($leaf in @('Media Cache Files', 'Peak Files')) {
        Clear-MoleAppCache -Path "$env:APPDATA\Adobe\Common\$leaf" -Description 'Adobe cache' -Processes @(
            'Adobe Premiere Pro', 'AfterFX', 'Adobe Media Encoder', 'Adobe Audition', 'Audition'
        )
    }

    $adobeCachePaths = @(
        "$env:LOCALAPPDATA\Adobe\*\Cache"
        "$env:LOCALAPPDATA\Adobe\*\CameraRaw\Cache"
        "$env:LOCALAPPDATA\Temp\Adobe"
    )
    
    foreach ($pattern in $adobeCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "Adobe cache"
            }
        }
    }
}

function Clear-AutodeskData {
    <#
    .SYNOPSIS
        Clean Autodesk application caches
    #>
    
    $autodeskCachePaths = @(
        "$env:LOCALAPPDATA\Autodesk\*\Cache"
        "$env:APPDATA\Autodesk\*\cache"
    )
    
    foreach ($pattern in $autodeskCachePaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "Autodesk cache"
            }
        }
    }
}

# ============================================================================
# Gaming Platform Cleanup
# ============================================================================

function Clear-GamingPlatformCaches {
    <#
    .SYNOPSIS
        Clean gaming platform caches (Steam, Epic, Origin, etc.)
    #>
    
    # Steam
    $steamPaths = @(
        "${env:ProgramFiles(x86)}\Steam\appcache\httpcache"
        "${env:ProgramFiles(x86)}\Steam\appcache\librarycache"
        "${env:ProgramFiles(x86)}\Steam\logs"
    )
    foreach ($path in $steamPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Steam $(Split-Path -Leaf $path)"
        }
    }
    
    # Epic Games Launcher
    $epicPaths = @(
        "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache"
        "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Logs"
    )
    foreach ($path in $epicPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Epic Games $(Split-Path -Leaf $path)"
        }
    }
    
    # EA App (Origin replacement)
    $eaPaths = @(
        "$env:LOCALAPPDATA\Electronic Arts\EA Desktop\cache"
        "$env:APPDATA\Origin\*\cache"
    )
    foreach ($pattern in $eaPaths) {
        $paths = Resolve-Path $pattern -ErrorAction SilentlyContinue
        foreach ($path in $paths) {
            if (Test-Path $path.Path) {
                Clear-DirectoryContents -Path $path.Path -Description "EA/Origin cache"
            }
        }
    }
    
    # GOG Galaxy
    $gogPaths = @(
        "$env:LOCALAPPDATA\GOG.com\Galaxy\webcache"
        "$env:PROGRAMDATA\GOG.com\Galaxy\logs"
    )
    foreach ($path in $gogPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "GOG Galaxy $(Split-Path -Leaf $path)"
        }
    }
    
    # Ubisoft Connect
    $ubiPaths = @(
        "$env:LOCALAPPDATA\Ubisoft Game Launcher\cache"
        "$env:LOCALAPPDATA\Ubisoft Game Launcher\logs"
    )
    foreach ($path in $ubiPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Ubisoft $(Split-Path -Leaf $path)"
        }
    }
    
    # Battle.net
    $battlenetPaths = @(
        "$env:APPDATA\Battle.net\Cache"
        "$env:APPDATA\Battle.net\Logs"
    )
    foreach ($path in $battlenetPaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Battle.net $(Split-Path -Leaf $path)"
        }
    }
}

# ============================================================================
# Game Media Cleanup (Replays, Screenshots, Recordings)
# ============================================================================

function Clear-GameMediaFiles {
    <#
    .SYNOPSIS
        Clean old game replays, screenshots, and recordings
    .DESCRIPTION
        Removes old media files from various gaming sources:
        - NVIDIA ShadowPlay/Highlights
        - AMD ReLive
        - Xbox Game Bar captures
        - Steam screenshots
        - OBS recordings
        - Windows Game DVR
        - GeForce Experience
        
        By default, only removes files older than 90 days.
        User media in standard Pictures/Videos folders is NOT touched
        unless it's in a game-specific subfolder.
    .PARAMETER DaysOld
        Minimum age of files to remove (default: 90 days)
    #>
    param(
        [int]$DaysOld = 90
    )
    
    Start-Section "Game media (>${DaysOld}d old)"
    
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    # One recursive enumeration per media root, then one extension filter. The
    # old per-extension loop read every root eleven times for the same files.
    $mediaExtensionPattern = '^\.(mp4|mkv|avi|mov|wmv|webm|png|jpg|jpeg|bmp|gif)$'
    $obsExtensionPattern = '^\.(mp4|mkv|flv|mov|ts)$'
    
    # -------------------------------------------------------------------------
    # NVIDIA ShadowPlay / GeForce Experience
    # -------------------------------------------------------------------------
    $nvidiaPaths = @(
        "$env:USERPROFILE\Videos\NVIDIA"                    # Default ShadowPlay location
        "$env:USERPROFILE\Videos\ShadowPlay"                # Alternative name
        "$env:USERPROFILE\Videos\GeForce Experience"        # GeForce Experience recordings
    )
    
    foreach ($basePath in $nvidiaPaths) {
        if (Test-Path $basePath) {
            $oldFiles = Get-ChildItem -Path $basePath -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match $mediaExtensionPattern }
            if ($oldFiles) {
                $paths = $oldFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "NVIDIA recordings (>${DaysOld}d)"
            }
        }
    }
    
    # NVIDIA Highlights (game-specific clips)
    $highlightsPath = "$env:USERPROFILE\Videos\NVIDIA\Highlights"
    if (Test-Path $highlightsPath) {
        $oldHighlights = Get-ChildItem -Path $highlightsPath -File -Recurse -ErrorAction SilentlyContinue |
                         Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match '\.(mp4|mkv|avi|mov)$' }
        if ($oldHighlights) {
            $paths = $oldHighlights | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "NVIDIA Highlights (>${DaysOld}d)"
        }
    }
    
    # -------------------------------------------------------------------------
    # AMD ReLive / Radeon Software
    # -------------------------------------------------------------------------
    $amdPaths = @(
        "$env:USERPROFILE\Videos\Radeon ReLive"
        "$env:USERPROFILE\Videos\AMD"
        "$env:USERPROFILE\Videos\Radeon"
    )
    
    foreach ($basePath in $amdPaths) {
        if (Test-Path $basePath) {
            $oldFiles = Get-ChildItem -Path $basePath -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match $mediaExtensionPattern }
            if ($oldFiles) {
                $paths = $oldFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "AMD ReLive recordings (>${DaysOld}d)"
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Xbox Game Bar / Windows Game DVR
    # -------------------------------------------------------------------------
    $xboxCapturesPath = "$env:USERPROFILE\Videos\Captures"
    if (Test-Path $xboxCapturesPath) {
        $oldFiles = Get-ChildItem -Path $xboxCapturesPath -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match $mediaExtensionPattern }
        if ($oldFiles) {
            $paths = $oldFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Xbox Game Bar captures (>${DaysOld}d)"
        }
    }
    
    # -------------------------------------------------------------------------
    # Steam Screenshots
    # -------------------------------------------------------------------------
    # Steam stores screenshots in userdata\<userid>\760\remote\<appid>\screenshots
    $steamUserDataPath = "${env:ProgramFiles(x86)}\Steam\userdata"
    if (Test-Path $steamUserDataPath) {
        $screenshotFolders = Get-ChildItem -Path $steamUserDataPath -Directory -ErrorAction SilentlyContinue |
                             ForEach-Object { Join-Path $_.FullName "760\remote" } |
                             Where-Object { Test-Path $_ }
        
        foreach ($folder in $screenshotFolders) {
            $oldScreenshots = Get-ChildItem -Path $folder -Filter "*.jpg" -File -Recurse -ErrorAction SilentlyContinue |
                              Where-Object { $_.LastWriteTime -lt $cutoffDate }
            if ($oldScreenshots) {
                $paths = $oldScreenshots | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Steam screenshots (>${DaysOld}d)"
            }
        }
    }
    
    # Also check common Steam screenshot export location
    $steamScreenshotsPath = "$env:USERPROFILE\Pictures\Steam Screenshots"
    if (Test-Path $steamScreenshotsPath) {
        $oldFiles = Get-ChildItem -Path $steamScreenshotsPath -Filter "*.jpg" -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($oldFiles) {
            $paths = $oldFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Steam exported screenshots (>${DaysOld}d)"
        }
    }
    
    # -------------------------------------------------------------------------
    # OBS Studio Recordings
    # -------------------------------------------------------------------------
    $obsRecordingsPath = "$env:USERPROFILE\Videos\OBS"
    if (Test-Path $obsRecordingsPath) {
        $oldFiles = Get-ChildItem -Path $obsRecordingsPath -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match $obsExtensionPattern }
        if ($oldFiles) {
            $paths = $oldFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "OBS recordings (>${DaysOld}d)"
        }
    }
    
    # -------------------------------------------------------------------------
    # Windows Game DVR (legacy location)
    # -------------------------------------------------------------------------
    $gameDvrPath = "$env:LOCALAPPDATA\Packages\Microsoft.XboxGamingOverlay_*\LocalState\GameDVR"
    $gameDvrPaths = Resolve-Path $gameDvrPath -ErrorAction SilentlyContinue
    foreach ($path in $gameDvrPaths) {
        if (Test-Path $path.Path) {
            $oldFiles = Get-ChildItem -Path $path.Path -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match '\.(mp4|png)$' }
            if ($oldFiles) {
                $paths = $oldFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Game DVR recordings (>${DaysOld}d)"
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Medal.tv Clips
    # -------------------------------------------------------------------------
    $medalPath = "$env:USERPROFILE\Videos\Medal"
    if (Test-Path $medalPath) {
        $oldFiles = Get-ChildItem -Path $medalPath -File -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match $mediaExtensionPattern }
        if ($oldFiles) {
            $paths = $oldFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Medal.tv clips (>${DaysOld}d)"
        }
    }
    
    # -------------------------------------------------------------------------
    # Overwolf / Outplayed Recordings
    # -------------------------------------------------------------------------
    $overwolfPaths = @(
        "$env:USERPROFILE\Videos\Overwolf"
        "$env:USERPROFILE\Videos\Outplayed"
    )
    foreach ($basePath in $overwolfPaths) {
        if (Test-Path $basePath) {
            $oldFiles = Get-ChildItem -Path $basePath -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoffDate -and $_.Extension -match $mediaExtensionPattern }
            if ($oldFiles) {
                $paths = $oldFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Overwolf/Outplayed recordings (>${DaysOld}d)"
            }
        }
    }
    
    # -------------------------------------------------------------------------
    # Game-specific replay folders (common locations)
    # -------------------------------------------------------------------------
    $gameReplayPaths = @(
        # Fortnite replays
        "$env:LOCALAPPDATA\FortniteGame\Saved\Demos"
        # League of Legends replays
        "$env:USERPROFILE\Documents\League of Legends\Replays"
        # Valorant
        "$env:LOCALAPPDATA\VALORANT\Saved\Logs"
        # Rocket League replays
        "$env:USERPROFILE\Documents\My Games\Rocket League\TAGame\Demos"
        # Call of Duty
        "$env:USERPROFILE\Documents\Call of Duty\players\theatre"
        # Apex Legends
        "$env:USERPROFILE\Saved Games\Respawn\Apex\assets\temp"
    )
    
    foreach ($path in $gameReplayPaths) {
        if (Test-Path $path) {
            $oldFiles = Get-ChildItem -Path $path -File -Recurse -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTime -lt $cutoffDate }
            if ($oldFiles) {
                $gameName = (Split-Path (Split-Path $path -Parent) -Leaf)
                $paths = $oldFiles | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "$gameName replays (>${DaysOld}d)"
            }
        }
    }
    
    Stop-Section
}

# ============================================================================
# Main Application Cleanup Function
# ============================================================================

function Invoke-AppCleanup {
    <#
    .SYNOPSIS
        Run all application-specific cleanup tasks
    #>
    param(
        [switch]$IncludeOrphaned,
        [switch]$IncludeGameMedia,
        [int]$GameMediaDaysOld = 90
    )
    
    Start-Section "Applications"
    
    # Productivity apps
    Clear-OfficeCache
    Clear-OneDriveCache
    Clear-GoogleDriveCache
    
    # Creative apps
    Clear-AdobeData
    Clear-AutodeskData
    
    # Gaming platforms
    Clear-GamingPlatformCaches
    
    Stop-Section
    
    # Game media (replays, screenshots, recordings)
    if ($IncludeGameMedia) {
        Clear-GameMediaFiles -DaysOld $GameMediaDaysOld
    }
    
    # Orphaned app data (separate section)
    if ($IncludeOrphaned) {
        Clear-OrphanedAppData -DaysOld 60
    }
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Get-InstalledPrograms, Find-OrphanedAppData, Clear-OfficeCache, etc.
