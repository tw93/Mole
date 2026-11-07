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
# Windows Logs
# ============================================================================

# Targets under %WINDIR% are absent on purpose: Test-SafePath protects that prefix
# outright, so a row there could only ever report nothing (elevated dry run, 2026-11-07).
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
        "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportQueue"
        "$env:PROGRAMDATA\Microsoft\Windows\WER\ReportArchive"
    )

    foreach ($path in $logPaths) {
        if (Test-Path $path) {
            Remove-OldFiles -Path $path -DaysOld $DaysOld -Description "$(Split-Path -Leaf $path) logs"
        }
    }
}

# ============================================================================
# Installer Cleanup
# ============================================================================

function Clear-InstallerCache {
    <#
    .SYNOPSIS
        Clean old Windows Installer logs from the temp folder
    #>

    # Installer logs in temp
    $installerLogs = Get-ChildItem -Path $env:TEMP -Filter "MSI*.LOG" -File -ErrorAction SilentlyContinue |
                     Where-Object { (Test-MoleOlderThan $_ (Get-Date).AddDays(-30)) }
    if ($installerLogs) {
        $paths = $installerLogs | ForEach-Object { $_.FullName }
        Remove-SafeItems -Paths $paths -Description "Old MSI logs"
    }
}

# ============================================================================
# Memory Dump Cleanup
# ============================================================================

function Clear-MemoryDumps {
    <#
    .SYNOPSIS
        Clean per-user application crash dumps
    #>

    $path = "$env:LOCALAPPDATA\CrashDumps"
    if (Test-Path $path -PathType Container) {
        Clear-DirectoryContents -Path $path -Description "CrashDumps"
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

    Start-Section "System cleanup"

    if (-not (Test-IsAdmin)) {
        Write-MoleWarning "Running without admin - some cleanup tasks will be skipped"
    }

    # Windows logs
    Clear-WindowsLogs -DaysOld 7

    # Installer cache
    Clear-InstallerCache

    # Memory dumps
    Clear-MemoryDumps

    # NVIDIA driver installer extraction folders and Delivery Optimization files
    Clear-NvidiaDriverInstallers
    Clear-DeliveryOptimizationFiles

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

# The provider warns "No active Delivery Optimization download or upload jobs"
# on an empty cache; that is not a Mole result line.
function Get-MoleDeliveryOptimizationFiles {
    try {
        return ,@(Get-CimInstance -Namespace $script:MoleDeliveryOptimizationNamespace -ClassName MSFT_DeliveryOptimizationFile -OperationTimeoutSec 10 -ErrorAction Stop -WarningAction SilentlyContinue)
    }
    catch { return $null }
}

function Get-MoleDeliveryOptimizationRoot {
    try {
        $config = @(Get-CimInstance -Namespace $script:MoleDeliveryOptimizationNamespace -ClassName MSFT_DeliveryOptimizationExtendedConfig -OperationTimeoutSec 10 -ErrorAction Stop -WarningAction SilentlyContinue)
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
            $null = Invoke-CimMethod -Namespace $script:MoleDeliveryOptimizationNamespace -ClassName MSFT_DeliveryOptimizationFile -MethodName Delete -Arguments @{ fileId = [string]$file.FileId; deletePinned = $false } -OperationTimeoutSec 10 -ErrorAction Stop -WarningAction SilentlyContinue
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
# Functions: Clear-WindowsLogs, Invoke-SystemCleanup, etc.
