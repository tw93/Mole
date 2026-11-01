# Mole - Cache Cleanup Module
# Cleans Windows and application caches

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_CACHES_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_CACHES_LOADED) { return }
$script:MOLE_CLEAN_CACHES_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"
. "$PSScriptRoot\cache_guard.ps1"

# ============================================================================
# Browser Caches
# ============================================================================

function Clear-BrowserCaches {
    <#
    .SYNOPSIS
        Clean browser cache directories
    #>
    
    Start-Section "Browser caches"
    
    $browsers = @(
        @{ Name = 'Chrome'; Root = 'Google\Chrome\User Data'; Processes = @('chrome'); RootCaches = @('ShaderCache', 'GrShaderCache') }
        @{ Name = 'Edge'; Root = 'Microsoft\Edge\User Data'; Processes = @('msedge'); RootCaches = @('ShaderCache') }
        @{ Name = 'Brave'; Root = 'BraveSoftware\Brave-Browser\User Data'; Processes = @('brave'); RootCaches = @() }
        @{ Name = 'Vivaldi'; Root = 'Vivaldi\User Data'; Processes = @('vivaldi'); RootCaches = @() }
    )
    foreach ($browser in $browsers) {
        $root = Join-Path $env:LOCALAPPDATA $browser.Root
        $lock = Join-Path $root 'lockfile'
        foreach ($profile in @(Get-MoleCacheProfiles $root)) {
            foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache')) {
                Clear-MoleAppCache -Path (Join-Path $profile.FullName $leaf) -Description "$($browser.Name) $leaf" -Processes $browser.Processes -LockPath $lock
            }
        }
        foreach ($leaf in $browser.RootCaches) {
            Clear-MoleAppCache -Path (Join-Path $root $leaf) -Description "$($browser.Name) $leaf" -Processes $browser.Processes -LockPath $lock
        }
    }

    # Firefox's disk/startup caches live in Local, not its roaming profile store.
    foreach ($profile in @(Get-MoleCacheProfiles "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles")) {
        foreach ($leaf in @('cache2', 'startupCache')) {
            $lock = "$env:APPDATA\Mozilla\Firefox\Profiles\$($profile.Name)\parent.lock"
            Clear-MoleAppCache -Path (Join-Path $profile.FullName $leaf) -Description 'Firefox cache' -Processes @('firefox') -LockPath $lock
        }
    }
    foreach ($profile in @(Get-MoleCacheProfiles "$env:APPDATA\Mozilla\Firefox\Profiles")) {
        Clear-MoleAppCache -Path (Join-Path $profile.FullName 'shader-cache') -Description 'Firefox cache' -Processes @('firefox') -LockPath (Join-Path $profile.FullName 'parent.lock')
    }

    # Keep Opera's legacy root layout and its newer Default/profile layout.
    foreach ($root in @("$env:APPDATA\Opera Software\Opera Stable", "$env:LOCALAPPDATA\Opera Software\Opera Stable")) {
        $profiles = @($root) + @(Get-MoleCacheProfiles $root | ForEach-Object { $_.FullName })
        foreach ($profile in $profiles) {
            foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache')) {
                Clear-MoleAppCache -Path (Join-Path $profile $leaf) -Description 'Opera cache' -Processes @('opera') -LockPath (Join-Path $root 'lockfile')
            }
        }
    }

    Stop-Section
}

# ============================================================================
# Application Caches
# ============================================================================

function Clear-AppCaches {
    <#
    .SYNOPSIS
        Clean common application caches
    #>
    
    Start-Section "Application caches"
    
    # Spotify Data and Storage may hold offline music; neither is an automatic target.

    # Discord
    $discordCachePaths = @(
        "$env:APPDATA\discord\Cache"
        "$env:APPDATA\discord\Code Cache"
        "$env:APPDATA\discord\GPUCache"
    )
    foreach ($path in $discordCachePaths) {
        if (Test-Path $path) {
            Clear-MoleAppCache -Path $path -Description "Discord cache" -Processes @('discord')
        }
    }
    
    # Vesktop 1.6.8 Windows profile: keep settings and persistent session stores.
    foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache')) {
        Clear-MoleAppCache -Path "$env:APPDATA\vesktop\sessionData\$leaf" -Description "Vesktop cache" -Processes @('vesktop')
    }

    # Slack
    $slackCachePaths = @(
        "$env:APPDATA\Slack\Cache"
        "$env:APPDATA\Slack\Code Cache"
        "$env:APPDATA\Slack\GPUCache"
    )
    foreach ($path in $slackCachePaths) {
        if (Test-Path $path) {
            Clear-MoleAppCache -Path $path -Description "Slack cache" -Processes @('slack')
        }
    }
    
    # Teams: keep blob storage and temporary app state; only known cache leaves.
    $teamsCachePaths = @(
        "$env:APPDATA\Microsoft\Teams\Cache"
        "$env:APPDATA\Microsoft\Teams\GPUCache"
    )
    foreach ($path in $teamsCachePaths) {
        if (Test-Path $path) {
            Clear-MoleAppCache -Path $path -Description "Teams cache" -Processes @('Teams')
        }
    }
    
    # New Teams: only named WebView disk-cache leaves, never the package root.
    $teamsRoot = "$env:LOCALAPPDATA\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\Microsoft\MSTeams\EBWebView"
    foreach ($profile in @(Get-MoleCacheProfiles $teamsRoot)) {
        foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache')) {
            Clear-MoleAppCache -Path (Join-Path $profile.FullName $leaf) -Description 'Teams cache' -Processes @('ms-teams') -LockPath (Join-Path $teamsRoot 'lockfile')
        }
    }

    foreach ($app in @('Cursor', 'Windsurf', 'Obsidian', 'Notion')) {
        foreach ($leaf in @('Cache', 'Code Cache', 'GPUCache')) {
            Clear-MoleAppCache -Path "$env:APPDATA\$app\$leaf" -Description "$app cache" -Processes @($app)
        }
    }

    # VS Code
    $vscodeCachePaths = @(
        "$env:APPDATA\Code\Cache"
        "$env:APPDATA\Code\CachedData"
        "$env:APPDATA\Code\CachedExtensions"
        "$env:APPDATA\Code\CachedExtensionVSIXs"
        "$env:APPDATA\Code\Code Cache"
        "$env:APPDATA\Code\GPUCache"
    )
    foreach ($path in $vscodeCachePaths) {
        if (Test-Path $path) {
            Clear-MoleAppCache -Path $path -Description "VS Code cache" -Processes @('Code')
        }
    }
    
    # Steam (download cache, not games)
    $steamCachePath = "${env:ProgramFiles(x86)}\Steam\appcache"
    if (Test-Path $steamCachePath) {
        Clear-DirectoryContents -Path $steamCachePath -Description "Steam app cache"
    }
    
    # Epic Games Launcher
    $epicCachePath = "$env:LOCALAPPDATA\EpicGamesLauncher\Saved\webcache"
    if (Test-Path $epicCachePath) {
        Clear-DirectoryContents -Path $epicCachePath -Description "Epic Games cache"
    }
    
    Stop-Section
}

# ============================================================================
# GPU Shader Caches
# ============================================================================

function Clear-GPUShaderCaches {
    <#
    .SYNOPSIS
        Clean GPU shader caches (NVIDIA, AMD, Intel, DirectX)
    .DESCRIPTION
        GPU drivers cache compiled shaders to improve game/app load times.
        These caches can grow very large (10GB+) and are safe to delete.
        They will be rebuilt automatically when needed, but every game then compiles
        its shaders again on its next launch, so mo clean runs this only with --gpu-shaders.
    #>
    
    Start-Section "GPU shader caches"
    
    # NVIDIA shader caches
    $nvidiaCachePaths = @(
        "$env:LOCALAPPDATA\NVIDIA\DXCache"
        "$env:LOCALAPPDATA\NVIDIA\GLCache"
        "$env:LOCALAPPDATA\NVIDIA Corporation\NV_Cache"
        "$env:TEMP\NVIDIA Corporation\NV_Cache"
    )
    foreach ($path in $nvidiaCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "NVIDIA shader cache"
        }
    }
    
    # AMD shader caches
    $amdCachePaths = @(
        "$env:LOCALAPPDATA\AMD\DXCache"
        "$env:LOCALAPPDATA\AMD\GLCache"
        "$env:LOCALAPPDATA\AMD\VkCache"
    )
    foreach ($path in $amdCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "AMD shader cache"
        }
    }
    
    # Intel shader caches
    $intelCachePaths = @(
        "$env:LOCALAPPDATA\Intel\ShaderCache"
        "$env:APPDATA\Intel\ShaderCache"
    )
    foreach ($path in $intelCachePaths) {
        if (Test-Path $path) {
            Clear-DirectoryContents -Path $path -Description "Intel shader cache"
        }
    }
    
    # DirectX shader cache (system-wide)
    $dxCachePath = "$env:LOCALAPPDATA\D3DSCache"
    if (Test-Path $dxCachePath) {
        Clear-DirectoryContents -Path $dxCachePath -Description "DirectX shader cache"
    }
    
    # DirectX pipeline cache
    $dxPipelinePath = "$env:LOCALAPPDATA\Microsoft\DirectX Shader Cache"
    if (Test-Path $dxPipelinePath) {
        Clear-DirectoryContents -Path $dxPipelinePath -Description "DirectX pipeline cache"
    }
    
    # Vulkan pipeline cache (common location)
    $vulkanCachePath = "$env:LOCALAPPDATA\VulkanCache"
    if (Test-Path $vulkanCachePath) {
        Clear-DirectoryContents -Path $vulkanCachePath -Description "Vulkan pipeline cache"
    }
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-BrowserCaches, Clear-GPUShaderCaches, Clear-AppCaches, etc.
