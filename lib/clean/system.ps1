# Mole - System Cleanup Module
# Cleans Windows system files that require administrator access

#Requires -Version 5.1
Set-StrictMode -Version Latest

# Prevent multiple sourcing
if ((Get-Variable -Name 'MOLE_CLEAN_SYSTEM_LOADED' -Scope Script -ErrorAction SilentlyContinue) -and $script:MOLE_CLEAN_SYSTEM_LOADED) { return }
$script:MOLE_CLEAN_SYSTEM_LOADED = $true

# Import dependencies
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$scriptDir\..\core\base.ps1"
. "$scriptDir\..\core\log.ps1"
. "$scriptDir\..\core\file_ops.ps1"

# ============================================================================
# System Temp Files
# ============================================================================

function Clear-SystemTempFiles {
    <#
    .SYNOPSIS
        Clean system-level temporary files (requires admin)
    #>

    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping system temp cleanup - requires admin"
        return
    }

    # Windows Temp folder
    $winTemp = "$env:WINDIR\Temp"
    if (Test-Path $winTemp) {
        Remove-OldFiles -Path $winTemp -DaysOld 7 -Description "Windows temp files"
    }

    # System temp (different from Windows temp)
    $systemTemp = "$env:SYSTEMROOT\Temp"
    if ((Test-Path $systemTemp) -and ($systemTemp -ne $winTemp)) {
        Remove-OldFiles -Path $systemTemp -DaysOld 7 -Description "System temp files"
    }
}

# ============================================================================
# Windows Logs
# ============================================================================

function Clear-WindowsLogs {
    <#
    .SYNOPSIS
        Clean Windows log files (requires admin)
    #>
    param([int]$DaysOld = 7)

    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping Windows logs cleanup - requires admin"
        return
    }

    # Windows Logs directory
    $logPaths = @(
        "$env:WINDIR\Logs\CBS"
        "$env:WINDIR\Logs\DISM"
        "$env:WINDIR\Logs\DPX"
        "$env:WINDIR\Logs\WindowsUpdate"
        "$env:WINDIR\Logs\SIH"
        "$env:WINDIR\Logs\waasmedia"
        "$env:WINDIR\Debug"
        "$env:WINDIR\Panther"
        "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportQueue"
        "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportArchive"
    )

    foreach ($path in $logPaths) {
        if (Test-Path $path) {
            Remove-OldFiles -Path $path -DaysOld $DaysOld -Description "$(Split-Path -Leaf $path) logs"
        }
    }

    # Setup logs (*.log files in Windows directory)
    $setupLogs = Get-ChildItem -Path "$env:WINDIR\*.log" -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-$DaysOld) }
    if ($setupLogs) {
        $paths = $setupLogs | ForEach-Object { $_.FullName }
        Remove-SafeItems -Paths $paths -Description "Windows setup logs"
    }
}

# ============================================================================
# Installer Cleanup
# ============================================================================

function Clear-InstallerCache {
    <#
    .SYNOPSIS
        Clean Windows Installer cache (orphaned patches)
    #>

    if (-not (Test-IsAdmin)) {
        return
    }

    # Windows Installer patch cache
    # WARNING: Be very careful here - only clean truly orphaned files
    $installerPath = "$env:WINDIR\Installer"

    # Only clean .tmp files and very old .msp files that are likely orphaned
    if (Test-Path $installerPath) {
        $tmpFiles = Get-ChildItem -Path $installerPath -Filter "*.tmp" -File -ErrorAction SilentlyContinue
        if ($tmpFiles) {
            $paths = $tmpFiles | ForEach-Object { $_.FullName }
            Remove-SafeItems -Paths $paths -Description "Installer temp files"
        }
    }

    # Installer logs in temp
    $installerLogs = Get-ChildItem -Path $env:TEMP -Filter "MSI*.LOG" -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
    if ($installerLogs) {
        $paths = $installerLogs | ForEach-Object { $_.FullName }
        Remove-SafeItems -Paths $paths -Description "Old MSI logs"
    }
}

# ============================================================================
# Component Store Cleanup
# ============================================================================

function Invoke-ComponentStoreCleanup {
    <#
    .SYNOPSIS
        Run Windows Component Store cleanup (DISM)
    #>

    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping component store cleanup - requires admin"
        return
    }

    if (Test-DryRunMode) {
        Write-DryRun "Component Store cleanup (DISM)"
        Set-SectionActivity
        return
    }

    try {
        Write-Info "Running Component Store cleanup (this may take a while)..."

        # Run DISM cleanup
        $result = Start-Process -FilePath "dism.exe" `
            -ArgumentList "/Online", "/Cleanup-Image", "/StartComponentCleanup" `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop

        if ($result.ExitCode -eq 0) {
            Write-Success "Component Store cleanup"
            Set-SectionActivity
        }
        else {
            Write-Debug "DISM returned exit code: $($result.ExitCode)"
        }
    }
    catch {
        Write-Debug "Component Store cleanup failed: $_"
    }
}

# ============================================================================
# Memory Dump Cleanup
# ============================================================================

function Clear-MemoryDumps {
    <#
    .SYNOPSIS
        Clean Windows memory dumps
    #>

    $dumpPaths = @(
        "$env:WINDIR\MEMORY.DMP"
        "$env:WINDIR\Minidump"
        "$env:LOCALAPPDATA\CrashDumps"
    )

    foreach ($path in $dumpPaths) {
        if (Test-Path $path -PathType Leaf) {
            # Single file (MEMORY.DMP)
            $null = Remove-SafeItem -Path $path -Description "Memory dump"
        }
        elseif (Test-Path $path -PathType Container) {
            # Directory (Minidump, CrashDumps)
            Clear-DirectoryContents -Path $path -Description "$(Split-Path -Leaf $path)"
        }
    }
}

# ============================================================================
# Disk Cleanup Tool Integration
# ============================================================================

function Invoke-DiskCleanupTool {
    <#
    .SYNOPSIS
        Run Windows built-in Disk Cleanup tool with predefined settings
    #>
    param([switch]$Full)

    if (-not (Test-IsAdmin)) {
        Write-Debug "Skipping Disk Cleanup tool - requires admin for full cleanup"
    }

    if (Test-DryRunMode) {
        Write-DryRun "Windows Disk Cleanup tool"
        return
    }

    # Set up registry keys for automated cleanup
    $cleanupKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"

    $cleanupItems = @(
        "Active Setup Temp Folders"
        "Downloaded Program Files"
        "Internet Cache Files"
        "Old ChkDsk Files"
        "Recycle Bin"
        "Setup Log Files"
        "System error memory dump files"
        "System error minidump files"
        "Temporary Files"
        "Temporary Setup Files"
        "Thumbnail Cache"
        "Windows Error Reporting Archive Files"
        "Windows Error Reporting Queue Files"
        "Windows Error Reporting System Archive Files"
        "Windows Error Reporting System Queue Files"
    )

    if ($Full -and (Test-IsAdmin)) {
        $cleanupItems += @(
            "Previous Installations"
            "Temporary Windows installation files"
            "Update Cleanup"
            "Windows Defender"
            "Windows Upgrade Log Files"
        )
    }

    # Enable cleanup items in registry
    foreach ($item in $cleanupItems) {
        $itemPath = Join-Path $cleanupKey $item
        if (Test-Path $itemPath) {
            Set-ItemProperty -Path $itemPath -Name "StateFlags0100" -Value 2 -Type DWord -ErrorAction SilentlyContinue
        }
    }

    try {
        # Run disk cleanup
        $process = Start-Process -FilePath "cleanmgr.exe" `
            -ArgumentList "/sagerun:100" `
            -Wait -PassThru -NoNewWindow -ErrorAction Stop

        if ($process.ExitCode -eq 0) {
            Write-Success "Windows Disk Cleanup"
            Set-SectionActivity
        }
    }
    catch {
        Write-Debug "Disk Cleanup failed: $_"
    }
}

# ============================================================================
# Main System Cleanup Function
# ============================================================================

function Invoke-SystemCleanup {
    <#
    .SYNOPSIS
        Run all system-level cleanup tasks (requires admin for full effect)
    #>
    param(
        [switch]$IncludeComponentStore,
        [switch]$IncludeDiskCleanup
    )

    Start-Section "System cleanup"

    if (-not (Test-IsAdmin)) {
        Write-MoleWarning "Running without admin - some cleanup tasks will be skipped"
    }

    # System temp files
    Clear-SystemTempFiles

    # Windows logs
    Clear-WindowsLogs -DaysOld 7

    # Installer cache
    Clear-InstallerCache

    # Memory dumps
    Clear-MemoryDumps

    # Optional: Component Store (can take a long time)
    if ($IncludeComponentStore) {
        Invoke-ComponentStoreCleanup
    }

    # Optional: Windows Disk Cleanup tool
    if ($IncludeDiskCleanup) {
        Invoke-DiskCleanupTool -Full
    }

    Stop-Section
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-SystemTempFiles, Clear-WindowsLogs, Invoke-SystemCleanup, etc.
