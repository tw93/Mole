# Mole - Clean Command
# Deep cleanup for Windows with dry-run support and whitelist

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Alias('dry-run')]
    [switch]$DryRun,
    
    [Alias('s')]
    [switch]$System,
    
    [Alias('game-media')]
    [switch]$GameMedia,
    
    [Alias('d')]
    [switch]$DebugMode,
    
    [Alias('w')]
    [switch]$Whitelist,
    
    [Alias('h')]
    [switch]$ShowHelp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Script location
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$libDir = Join-Path (Split-Path -Parent $scriptDir) "lib"

# Import core modules
. "$libDir\core\base.ps1"
. "$libDir\core\log.ps1"
. "$libDir\core\ui.ps1"
. "$libDir\core\file_ops.ps1"

# Import cleanup modules
. "$libDir\clean\user.ps1"
. "$libDir\clean\caches.ps1"
. "$libDir\clean\dev.ps1"
. "$libDir\clean\apps.ps1"
. "$libDir\clean\system.ps1"

# Clean refuses key, browser profile and transcript stores (lib/core/base.ps1).
$script:MoleCleanPathGuard = $true

# ============================================================================
# Configuration
# ============================================================================

$script:ExportListFile = "$env:USERPROFILE\.config\mole\clean-list.txt"

# ============================================================================
# Help
# ============================================================================

function Show-CleanHelp {
    $esc = [char]27
    Write-Host ""
    Write-Host "$esc[1;35mmo clean$esc[0m - Deep cleanup for Windows"
    Write-Host ""
    Write-Host "$esc[33mUsage:$esc[0m mo clean [options]"
    Write-Host ""
    Write-Host "$esc[33mOptions:$esc[0m"
    Write-Host "  --dry-run      Preview changes without deleting (recommended first run)"
    Write-Host "  --system       Include system-level cleanup (requires admin)"
    Write-Host "  --game-media   Clean old game replays, screenshots, recordings (>90d)"
    Write-Host "  --whitelist    Manage protected paths"
    Write-Host "  --debug        Enable debug logging"
    Write-Host "  --help         Show this help message"
    Write-Host ""
    Write-Host "$esc[33mExamples:$esc[0m"
    Write-Host "  mo clean --dry-run     # Preview what would be cleaned"
    Write-Host "  mo clean               # Run standard cleanup"
    Write-Host "  mo clean --game-media  # Include old game media cleanup"
    Write-Host "  mo clean --system      # Include system cleanup (as admin)"
    Write-Host ""
}

# ============================================================================
# Whitelist Management
# ============================================================================

function Edit-Whitelist {
    $whitelistPath = $script:Config.WhitelistFile
    $whitelistDir = Split-Path -Parent $whitelistPath

    # Ensure directory exists
    if (-not (Test-Path $whitelistDir)) {
        New-Item -ItemType Directory -Path $whitelistDir -Force | Out-Null
    }

    # Create default whitelist if doesn't exist
    if (-not (Test-Path $whitelistPath)) {
        $defaultContent = @"
# Mole Whitelist - Paths listed here will never be cleaned
# Use full paths or patterns with wildcards (*)
#
# Examples:
# C:\Users\YourName\Documents\ImportantProject
# C:\Users\*\AppData\Local\MyApp
# $env:LOCALAPPDATA\CriticalApp
#
# Add your protected paths below:

"@
        Set-Content -Path $whitelistPath -Value $defaultContent
    }

    # Open in default editor
    Write-Info "Opening whitelist file: $whitelistPath"
    Start-Process notepad.exe -ArgumentList $whitelistPath -Wait

    Write-Success "Whitelist saved"
}

# ============================================================================
# Cleanup Summary
# ============================================================================

function Show-CleanupSummary {
    param(
        [hashtable]$Stats,
        [bool]$IsDryRun
    )

    $green = Get-MoleColor -Name Green
    $nc = Get-MoleColor -Name NC
    $heading = if ($IsDryRun) { 'Dry run complete - no changes made' } else { 'Cleanup complete' }
    $details = @()
    if ($Stats.TotalSizeKB -gt 0) {
        $size = Format-ByteSize -Bytes ($Stats.TotalSizeKB * 1024)
        if ($IsDryRun) {
            $details += "Potential space: ${green}${size}${nc} | Items: $($Stats.FilesCleaned)"
        }
        else {
            $details += "Tracked cleanup: ${green}${size}${nc} | Items cleaned: $($Stats.FilesCleaned)"
        }
    }
    elseif ($Stats.ContainsKey('OwnerCleanups') -and $Stats.OwnerCleanups -gt 0) {
        $details += $(if ($IsDryRun) { 'Tool caches are listed for review.' } else { 'Tool cache cleanup completed.' })
    }
    else {
        $details += $(if ($IsDryRun) { 'No significant reclaimable space detected.' } else { 'System was already clean; no additional space freed.' })
    }
    $details += "Free space: $(Get-FreeSpace)"
    if ($IsDryRun -and ($Stats.TotalSizeKB -gt 0 -or ($Stats.ContainsKey('OwnerCleanups') -and $Stats.OwnerCleanups -gt 0))) {
        $details += "Detailed file list: $($script:ExportListFile)"
    }
    Show-SummaryBlock -Heading $heading -Details $details
}

# ============================================================================
# Main Cleanup Flow
# ============================================================================

function Start-Cleanup {
    param(
        [bool]$IsDryRun,
        [bool]$IncludeSystem,
        [bool]$IncludeGameMedia
    )

    $esc = [char]27

    # Clear screen
    Clear-Host
    Write-Host ""
    Write-Host "$esc[1;35mClean Your Windows$esc[0m"
    Write-Host ""

    # Show mode
    if ($IsDryRun) {
        Write-Host "$esc[33mDry Run Mode$esc[0m - Preview only, no deletions"
        Write-Host ""

        # Prepare export file
        $exportDir = Split-Path -Parent $script:ExportListFile
        if (-not (Test-Path $exportDir)) {
            New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
        }

        $header = @"
# Mole Cleanup Preview - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
#
# How to protect files:
# 1. Copy any path below to $($script:Config.WhitelistFile)
# 2. Run: mo clean --whitelist
#

"@
        Set-Content -Path $script:ExportListFile -Value $header
    }
    else {
        Write-Host "$esc[90m$($script:Icons.Solid) Use --dry-run to preview, --whitelist to manage protected paths$esc[0m"
        Write-Host ""
    }

    # System cleanup confirmation
    if ($IncludeSystem -and -not $IsDryRun) {
        if (-not (Test-IsAdmin)) {
            Write-MoleWarning "System cleanup requires administrator privileges"
            Write-Host "  Run PowerShell as Administrator for full cleanup"
            Write-Host ""
            $IncludeSystem = $false
        }
        else {
            Write-Host "$esc[32m$($script:Icons.Success)$esc[0m Running with Administrator privileges"
            Write-Host ""
        }
    }

    # Show system info
    $winVer = Get-WindowsVersion
    Write-Host "$esc[34m$($script:Icons.Admin)$esc[0m $($winVer.Name) | Free space: $(Get-FreeSpace)"
    Write-Host ""

    # Reset stats
    Reset-CleanupStats
    Set-DryRunMode -Enabled $IsDryRun

    # Run cleanup modules
    try {
        # User essentials (temp, logs, etc.)
        Invoke-UserCleanup -TempDaysOld 7 -LogDaysOld 7

        # Browser caches
        Clear-BrowserCaches

        # GPU shader caches (NVIDIA, AMD, Intel, DirectX)
        Clear-GPUShaderCaches

        # Application caches
        Clear-AppCaches

        # Developer tools
        Invoke-DevToolsCleanup

        # Applications cleanup (with optional game media)
        if ($IncludeGameMedia) {
            Invoke-AppCleanup -IncludeGameMedia -GameMediaDaysOld 90
        }
        else {
            Invoke-AppCleanup
        }

        # System cleanup (if requested and admin)
        if ($IncludeSystem -and (Test-IsAdmin)) {
            Invoke-SystemCleanup
        }
    }
    catch {
        Write-MoleError "Cleanup error: $_"
    }
    finally {
        $script:CurrentSection.Active = $false
        Stop-Spinner
    }

    # Get final stats
    $stats = Get-CleanupStats

    # Show summary
    Show-CleanupSummary -Stats $stats -IsDryRun $IsDryRun
}

# ============================================================================
# Main Entry Point
# ============================================================================

function Main {
    # Enable debug if requested
    if ($DebugMode) {
        Enable-DebugMode
        $DebugPreference = "Continue"
    }

    # Show help
    if ($ShowHelp) {
        Show-CleanHelp
        return
    }

    # Manage whitelist
    if ($Whitelist) {
        Edit-Whitelist
        return
    }

    # Set dry-run mode
    $effectiveDryRun = $DryRun -or ($env:MOLE_DRY_RUN -eq '1')
    if ($effectiveDryRun) {
        $env:MOLE_DRY_RUN = "1"
    }
    else {
        $env:MOLE_DRY_RUN = "0"
    }

    # Run cleanup
    Start-Cleanup -IsDryRun $effectiveDryRun -IncludeSystem $System -IncludeGameMedia $GameMedia
}

# Run main
Main
