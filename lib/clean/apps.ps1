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
                Clear-MoleAppCache -Path $path.Path -Description "Autodesk cache" -Processes @('acad', 'Revit', 'maya', '3dsmax', 'Inventor', 'Fusion360')
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
    
    # Each launcher's caches go only while it is closed, and its logs at seven days,
    # the way Mole for Windows holds them. Steam's own folder is under Program Files,
    # which stays protected; its web cache lives in the profile.
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\Steam\htmlcache" -Description "Steam web cache" -Processes @('steam', 'steamwebhelper')

    # Epic Games Launcher
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache" -Description "Epic Games webcache" -Processes @('EpicGamesLauncher')
    Clear-MoleOwnerLogs -Path "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\Logs" -Description "Epic Games logs" -Processes @('EpicGamesLauncher')

    # EA app (Origin replacement). 13.822 keeps a whole Chromium profile in
    # CEF\<n>\EADesktop\BrowserCache, cookies and its sign-in store included, so
    # only the cache leaves go (Windows 2026-11-10). EADesktop holds them; its
    # EABackgroundService service keeps running after the window closes.
    $eaProcesses = @('EADesktop', 'EABackgroundService', 'Origin')
    foreach ($profile in @(Get-MoleCacheProfiles "$env:LOCALAPPDATA\Electronic Arts\EA Desktop\CEF")) {
        foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache', 'DawnCache')) {
            Clear-MoleAppCache -Path (Join-Path $profile.FullName "EADesktop\BrowserCache\$leaf") -Description "EA app $leaf" -Processes @('EADesktop')
        }
    }
    foreach ($path in @(Resolve-Path "$env:APPDATA\Origin\*\cache" -ErrorAction SilentlyContinue)) {
        Clear-MoleAppCache -Path $path.Path -Description "Origin cache" -Processes $eaProcesses
    }

    # GOG Galaxy
    Clear-MoleAppCache -Path "$env:LOCALAPPDATA\GOG.com\Galaxy\webcache" -Description "GOG Galaxy webcache" -Processes @('GalaxyClient')
    Clear-MoleOwnerLogs -Path "$env:PROGRAMDATA\GOG.com\Galaxy\logs" -Description "GOG Galaxy logs" -Processes @('GalaxyClient')

    # Ubisoft Connect
    $ubisoftProcesses = @('upc', 'UbisoftConnect')
    # cache\http2 is a whole Chromium user-data folder whose Default keeps Login
    # Data and Cookies, so only its cache leaves go (Windows 2026-11-10).
    $ubisoftData = "$env:LOCALAPPDATA\Ubisoft Game Launcher\cache\http2"
    foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache', 'DawnGraphiteCache', 'DawnWebGPUCache')) {
        Clear-MoleAppCache -Path "$ubisoftData\Default\$leaf" -Description "Ubisoft Connect $leaf" -Processes $ubisoftProcesses
    }
    foreach ($leaf in @('ShaderCache', 'GrShaderCache', 'GraphiteDawnCache')) {
        Clear-MoleAppCache -Path "$ubisoftData\$leaf" -Description "Ubisoft Connect $leaf" -Processes $ubisoftProcesses
    }
    Clear-MoleOwnerLogs -Path "$env:LOCALAPPDATA\Ubisoft Game Launcher\logs" -Description "Ubisoft logs" -Processes $ubisoftProcesses

    # Battle.net
    Clear-MoleAppCache -Path "$env:APPDATA\Battle.net\Cache" -Description "Battle.net Cache" -Processes @('Battle.net')
    Clear-MoleOwnerLogs -Path "$env:APPDATA\Battle.net\Logs" -Description "Battle.net logs" -Processes @('Battle.net')
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
                        Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match $mediaExtensionPattern }
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
                         Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match '\.(mp4|mkv|avi|mov)$' }
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
                        Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match $mediaExtensionPattern }
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
                    Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match $mediaExtensionPattern }
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
                              Where-Object { (Test-MoleOlderThan $_ $cutoffDate) }
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
                    Where-Object { (Test-MoleOlderThan $_ $cutoffDate) }
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
                    Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match $obsExtensionPattern }
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
                        Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match '\.(mp4|png)$' }
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
                    Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match $mediaExtensionPattern }
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
                        Where-Object { (Test-MoleOlderThan $_ $cutoffDate) -and $_.Extension -match $mediaExtensionPattern }
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
                        Where-Object { (Test-MoleOlderThan $_ $cutoffDate) }
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
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-OfficeCache, etc.
