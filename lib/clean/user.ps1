# Mole - User Cleanup Module
# Cleans user-level temporary files, caches, and downloads

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_USER_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_USER_LOADED) { return }
$script:MOLE_CLEAN_USER_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# Windows Temp Files Cleanup
# ============================================================================

function Clear-UserTempFiles {
    <#
    .SYNOPSIS
        Clean user temporary files
    #>
    param([int]$DaysOld = 7)
    
    # User temp directory
    $userTemp = $env:TEMP
    if (Test-Path $userTemp) {
        Remove-OldFiles -Path $userTemp -DaysOld $DaysOld -Description "User temp files"
    }
    
    # Windows Temp (if accessible)
    $winTemp = "$env:WINDIR\Temp"
    if ((Test-Path $winTemp) -and (Test-IsAdmin)) {
        Remove-OldFiles -Path $winTemp -DaysOld $DaysOld -Description "Windows temp files"
    }
    
}

# ============================================================================
# Downloads Folder Cleanup
# ============================================================================

function Clear-OldDownloads {
    <#
    .SYNOPSIS
        Clean old files from Downloads folder (with user confirmation pattern)
    #>
    param([int]$DaysOld = 30)
    
    $downloadsPath = [Environment]::GetFolderPath('UserProfile') + '\Downloads'
    
    if (-not (Test-Path $downloadsPath)) {
        return
    }
    
    # Find old installers and archives
    $patterns = @('*.exe', '*.msi', '*.zip', '*.7z', '*.rar', '*.tar.gz', '*.iso')
    $cutoffDate = (Get-Date).AddDays(-$DaysOld)
    
    $oldFiles = @()
    foreach ($pattern in $patterns) {
        $files = Get-ChildItem -Path $downloadsPath -Filter $pattern -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt $cutoffDate }
        if ($files) {
            $oldFiles += $files
        }
    }
    
    if ($oldFiles.Count -gt 0) {
        $paths = $oldFiles | ForEach-Object { $_.FullName }
        Remove-SafeItems -Paths $paths -Description "Old downloads (>${DaysOld}d)"
    }
}

# ============================================================================
# Recycle Bin Cleanup
# ============================================================================

function Clear-RecycleBin {
    <#
    .SYNOPSIS
        Empty the Recycle Bin
    #>
    
    if (Test-DryRunMode) {
        Write-DryRun "Recycle Bin (would empty)"
        Set-SectionActivity
        return
    }
    
    try {
        # Use Shell.Application COM object
        $shell = New-Object -ComObject Shell.Application
        $recycleBin = $shell.Namespace(0xA)  # Recycle Bin
        $items = $recycleBin.Items()
        
        if ($items.Count -gt 0) {
            # Calculate size
            $totalSize = 0
            foreach ($item in $items) {
                $totalSize += $item.Size
            }
            
            # Clear using Clear-RecycleBin cmdlet (Windows 10+)
            Clear-RecycleBin -Force -ErrorAction SilentlyContinue
            
            $sizeHuman = Format-ByteSize -Bytes $totalSize
            Write-Success "Recycle Bin $($script:Colors.Green)($sizeHuman)$($script:Colors.NC)"
            Set-SectionActivity
        }
    }
    catch {
        Write-Debug "Could not clear Recycle Bin: $_"
    }
}

# ============================================================================
# Windows Error Reports Cleanup
# ============================================================================

function Clear-ErrorReports {
    <#
    .SYNOPSIS
        Clean Windows Error Reporting files
    #>
    param([int]$DaysOld = 7)
    
    # One WER root, listed one level deep: a recursive listing counted every
    # report folder and the files inside it again. CrashDumps is handled with
    # the memory dumps below, so it is not listed here as well.
    $werPaths = @(
        "$env:LOCALAPPDATA\Microsoft\Windows\WER"
    )
    
    foreach ($path in $werPaths) {
        if (Test-Path $path) {
            $items = Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue
            if ($items) {
                $paths = $items | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Error reports"
            }
        }
    }
    
    # Memory dumps
    $dumpPaths = @(
        "$env:LOCALAPPDATA\CrashDumps"
    )
    
    foreach ($path in $dumpPaths) {
        $dumps = Get-ChildItem -Path $path -Filter "*.dmp" -ErrorAction SilentlyContinue
        if ($dumps) {
            $paths = $dumps | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Memory dumps"
        }
    }
}

# ============================================================================
# Windows Prefetch Cleanup (requires admin)
# ============================================================================

function Clear-Prefetch {
    <#
    .SYNOPSIS
        Clean Windows Prefetch files (requires admin)
    #>
    param([int]$DaysOld = 14)
    
    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping Prefetch cleanup - requires admin"
        return
    }
    
    $prefetchPath = "$env:WINDIR\Prefetch"
    
    if (Test-Path $prefetchPath) {
        Remove-OldFiles -Path $prefetchPath -DaysOld $DaysOld -Description "Prefetch files"
    }
}

# ============================================================================
# Log Files Cleanup
# ============================================================================

function Clear-UserLogs {
    <#
    .SYNOPSIS
        Clean old log files from common locations
    #>
    param([int]$DaysOld = 7)
    
    $logLocations = @(
        "$env:LOCALAPPDATA\Temp\*.log"
        "$env:APPDATA\*.log"
    )
    
    foreach ($location in $logLocations) {
        $parent = Split-Path -Parent $location
        $filter = Split-Path -Leaf $location
        
        if (Test-Path $parent) {
            $logs = Get-ChildItem -Path $parent -Filter $filter -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$DaysOld) }
            
            if ($logs) {
                $paths = $logs | ForEach-Object { $_.FullName }
                Remove-SafeItems -Paths $paths -Description "Old log files"
            }
        }
    }
}

# ============================================================================
# Main User Cleanup Function
# ============================================================================

function Invoke-UserCleanup {
    <#
    .SYNOPSIS
        Run all user-level cleanup tasks
    #>
    param(
        [int]$TempDaysOld = 7,
        [int]$DownloadsDaysOld = 30,
        [int]$LogDaysOld = 7,
        [switch]$IncludeDownloads,
        [switch]$IncludeRecycleBin
    )
    
    Start-Section "User essentials"
    
    # Always clean these
    Clear-UserTempFiles -DaysOld $TempDaysOld
    Clear-ErrorReports -DaysOld 7
    Clear-UserLogs -DaysOld $LogDaysOld
    Clear-Prefetch -DaysOld 14
    
    # Optional: Downloads cleanup
    if ($IncludeDownloads) {
        Clear-OldDownloads -DaysOld $DownloadsDaysOld
    }
    
    # Optional: Recycle Bin
    if ($IncludeRecycleBin) {
        Clear-RecycleBin
    }
    
    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-UserTempFiles, Clear-OldDownloads, Clear-RecycleBin, etc.
