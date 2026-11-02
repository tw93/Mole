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

    # NVIDIA driver installer extraction folders and Delivery Optimization files
    Clear-NvidiaDriverInstallers
    Clear-DeliveryOptimizationFiles

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
# NVIDIA driver installers
# ============================================================================

# NVIDIA's driver package unpacks each version into C:\NVIDIA\DisplayDriver
# before it checks the hardware and never removes it; the installed driver does
# not read it again. Only version folders whose every entry is a week old go,
# never the rest of C:\NVIDIA, and nothing while a process runs from the folder.
# Both checks run again at the removal boundary.
# A process started from the folder is an installer at work; an unreadable
# process list cannot rule one out. CIM reports image paths across bitness,
# where Process.Path from 32-bit PowerShell is empty for 64-bit processes.
# Only protected system processes come back without a path, and none of
# them runs from C:\NVIDIA.
function Test-MoleNvidiaInstallerRunning {
    param([string]$Root)
    try { $processes = @(Get-CimInstance -ClassName Win32_Process -Property ExecutablePath -OperationTimeoutSec 10 -ErrorAction Stop) }
    catch { return $true }
    if ($processes.Count -eq 0) { return $true }
    $prefix = $Root.TrimEnd('\') + '\'
    foreach ($process in $processes) {
        $path = [string]$process.ExecutablePath
        if ($path -and $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Clear-NvidiaDriverInstallers {
    param([int]$DaysOld = 7)
    if (-not (Test-IsAdmin)) { return }
    $root = Join-Path $env:SystemDrive 'NVIDIA\DisplayDriver'
    $snapshot = Get-MolePathSnapshot -Path $root
    if (-not $snapshot) { return }
    $cutoff = (Get-Date).AddDays(-$DaysOld)
    try { $versions = @([IO.Directory]::EnumerateDirectories($root) | Select-Object -First 64) }
    catch { return }
    if (-not (Test-MolePathSnapshot $snapshot)) { return }
    if (Test-MoleNvidiaInstallerRunning -Root $root) { return }
    foreach ($version in $versions) {
        $versionPath = $version
        if (-not (Test-MoleOldErrorReport -Path $versionPath -Cutoff $cutoff -MaxEntries 50000 -Seconds 10)) { continue }
        $guard = { (Test-MolePathSnapshot $snapshot) -and -not (Test-MoleNvidiaInstallerRunning -Root $root) -and (Test-MoleOldErrorReport -Path $versionPath -Cutoff $cutoff -MaxEntries 50000 -Seconds 10) }
        Remove-SafeItems -Paths @($versionPath) -Description 'NVIDIA driver installers' -CanRemove $guard
    }
}

# ============================================================================
# Delivery Optimization files
# ============================================================================

# Windows Update, Store and Edge downloads the Delivery Optimization service
# keeps to share with other PCs; Disk Cleanup calls them safe to delete. The
# files belong to the service, so Mole never deletes them itself: it asks the
# service, file by file, for finished, unpinned files only, and counts what the
# service no longer lists afterwards. A user whitelist on the cache root, an
# unanswered provider or an incomplete listing keeps everything.
$script:MoleDeliveryOptimizationNamespace = 'root/Microsoft/Windows/DeliveryOptimization'

function Get-MoleDeliveryOptimizationFiles {
    try {
        return ,@(Get-CimInstance -Namespace $script:MoleDeliveryOptimizationNamespace -ClassName MSFT_DeliveryOptimizationFile -OperationTimeoutSec 10 -ErrorAction Stop)
    }
    catch { return $null }
}

function Get-MoleDeliveryOptimizationRoot {
    try {
        $config = @(Get-CimInstance -Namespace $script:MoleDeliveryOptimizationNamespace -ClassName MSFT_DeliveryOptimizationExtendedConfig -OperationTimeoutSec 10 -ErrorAction Stop)
        foreach ($item in $config) {
            $folder = [string]$item.WorkingDirectory
            if ($folder) { return $folder }
        }
    }
    catch { }
    return $null
}

function Test-MoleDeliveryOptimizationClearable {
    param($File)
    # SwarmStatus 1 Complete and 2 Caching are finished downloads; 0 and 3 are not.
    # A value the provider returns in another shape is not clearable.
    $id = [string]$File.FileId
    $status = 0; $size = 0L
    if (-not [int]::TryParse([string]$File.Status, [ref]$status)) { return $false }
    if (-not [long]::TryParse([string]$File.FileSizeInCache, [ref]$size)) { return $false }
    return ($id -match '^[A-Za-z0-9+/=_-]{1,128}$' -and $status -in @(1, 2) -and
        $File.IsPinned -eq $false -and $size -gt 0)
}

# A wildcard row whose literal prefix may overlap the root is resolved against
# what is on disk: every ancestor and every entry below the root is checked,
# without entering links. A match, a link, an unreadable entry or a walk that
# does not finish keeps every file.
function Test-MoleDeliveryOptimizationTreeWhitelisted {
    param([string]$Root, $State)
    # A trimmed drive root such as D: means the current folder on that drive.
    if ($Root -match '^[A-Za-z]:$') { $Root += '\' }
    try {
        $parent = Split-Path -Path $Root -Parent
        while ($parent) {
            if (Test-Whitelisted -Path $parent -State $State) { return $true }
            $next = Split-Path -Path $parent -Parent
            if (-not $next -or $next -eq $parent) { break }
            $parent = $next
        }
        foreach ($item in @(Get-TreeItemsNoFollow -Path $Root)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            if (Test-Whitelisted -Path $item.FullName -State $State) { return $true }
        }
        return $false
    }
    catch {
        Write-Debug "Delivery Optimization tree unverified: $_"
        return $true
    }
}

# The service deletes inside its root, so a whitelist row on the root, above
# it, or anywhere below it keeps every file; unknown protection keeps them too.
# A wildcard row that may reach this subtree is checked against the tree.
function Test-MoleDeliveryOptimizationProtected {
    param([string]$Root)
    $state = Get-WhitelistState
    $roots = @($Root.TrimEnd('\'))
    $info = Resolve-MoleExistingPathInfo -Path $Root
    if ($info.Exists -and $info.Path -and -not [string]::Equals($info.Path.TrimEnd('\'), $roots[0], [StringComparison]::OrdinalIgnoreCase)) {
        $roots += $info.Path.TrimEnd('\')
    }
    foreach ($candidate in $roots) {
        if (Test-Whitelisted -Path $candidate -State $state) { return $true }
        $prefix = $candidate + '\'
        $walk = $false
        foreach ($entry in @($state.Patterns)) {
            $pattern = [string]$entry
            if (-not $pattern) { continue }
            if ($pattern.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            $wildcard = $pattern.IndexOfAny([char[]]@('*', '?', '[', '`'))
            if ($wildcard -lt 0) { continue }
            $fixed = $pattern.Substring(0, $wildcard)
            if (-not $fixed -or $fixed.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                    $prefix.StartsWith($fixed, [StringComparison]::OrdinalIgnoreCase)) { $walk = $true }
        }
        if ($walk -and (Test-MoleDeliveryOptimizationTreeWhitelisted -Root $candidate -State $state)) { return $true }
    }
    return $false
}

function Clear-DeliveryOptimizationFiles {
    $files = Get-MoleDeliveryOptimizationFiles
    if ($null -eq $files) { return }
    $clearable = @($files | Where-Object { Test-MoleDeliveryOptimizationClearable $_ })
    if ($clearable.Count -eq 0) { return }
    $root = Get-MoleDeliveryOptimizationRoot
    if (-not $root) { return }
    if (Test-MoleDeliveryOptimizationProtected -Root $root) { return }
    $bytes = 0L
    foreach ($file in $clearable) { $bytes += [long]$file.FileSizeInCache }
    $description = 'Delivery Optimization files'
    if (Test-DryRunMode) {
        Add-DryRunListEntries -Description $description -Paths @($root)
        $script:TotalSizeCleaned += [Math]::Floor($bytes / 1024)
        $script:FilesCleaned += $clearable.Count
        $script:TotalItems++
        Write-DryRun "$description $($script:Colors.Yellow)($(Format-ByteSize -Bytes $bytes) dry)$($script:Colors.NC)"
        Set-SectionActivity
        return
    }
    if (Test-MoleDeliveryOptimizationProtected -Root $root) { return }
    foreach ($file in $clearable) {
        try {
            $null = Invoke-CimMethod -Namespace $script:MoleDeliveryOptimizationNamespace -ClassName MSFT_DeliveryOptimizationFile -MethodName Delete -Arguments @{ fileId = [string]$file.FileId; deletePinned = $false } -OperationTimeoutSec 10 -ErrorAction Stop
        }
        catch { Write-Debug "Delivery Optimization delete failed: $_" }
    }
    $after = Get-MoleDeliveryOptimizationFiles
    if ($null -eq $after) {
        Write-MoleOperation -Action "FAILED" -Path $root -Detail "MSFT_DeliveryOptimizationFile.Delete: listing unavailable afterwards"
        return
    }
    $left = @{}
    foreach ($file in $after) { $left[[string]$file.FileId] = $true }
    $removed = @($clearable | Where-Object { -not $left.ContainsKey([string]$_.FileId) })
    $freed = 0L
    foreach ($file in $removed) { $freed += [long]$file.FileSizeInCache }
    if ($removed.Count -eq 0) {
        Write-MoleOperation -Action "FAILED" -Path $root -Detail "MSFT_DeliveryOptimizationFile.Delete: nothing removed"
        return
    }
    Write-MoleOperation -Action "OWNER" -Path $root -Detail "MSFT_DeliveryOptimizationFile.Delete: $($removed.Count) of $($clearable.Count) files"
    $script:OwnerCleanups++
    $script:TotalSizeCleaned += [Math]::Floor($freed / 1024)
    $script:FilesCleaned += $removed.Count
    $script:TotalItems++
    Write-Success "$description $($script:Colors.Green)($(Format-ByteSize -Bytes $freed))$($script:Colors.NC)"
    Set-SectionActivity
}

# ============================================================================
# Exports
# ============================================================================
# Functions: Clear-SystemTempFiles, Clear-WindowsLogs, Invoke-SystemCleanup, etc.
